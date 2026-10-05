require_relative 'type_checker/type'
require_relative 'type_checker/signature'
require_relative 'type_checker/unifier'
require_relative 'type_checker/renderer'
require_relative 'type_checker/conflict'
require_relative 'type_checker/result'
require_relative 'type_checker/built_in'
require_relative 'type_checker/analyzer'

module Dentaku
  module TypeChecker
  # Statically type-checks formulas before any data exists.
  #
  #   checker = Dentaku::Calculator.new
  #   result = checker.type_check('price * quantity', price: :numeric, quantity: :numeric)
  #   result.ok?            #=> true
  #   result.rendered_type  #=> "numeric"
  #
  # Variable declarations may be symbols (:numeric, :bool, :string, :date)
  # or Type objects (e.g. Type.array(:string)). Function signatures are
  # given as "params -> result" strings (e.g. "array(T) -> T") and are
  # instantiated fresh at every call, so one polymorphic function can be
  # used on string arrays and numeric arrays without sharing constraints.
  class Checker
    Serial = Struct.new(:counter) do
      def initialize
        super(0)
      end

      def next_id
        self.counter += 1
        "t#{counter}".to_sym
      end
    end

    def initialize(calculator: nil, types: {}, signatures: {})
      @calculator = calculator
      @declared_types = types
      @signatures = normalize_signatures(signatures)
    end

    # check one expression; returns a TypeChecker::Result
    def check(expression, types: nil, signatures: nil, name: nil)
      run_batch({ (name || :result) => expression }, types: types, signatures: signatures)
    end

    # check a set of connected formulas (a formula may reference another
    # formula's output). Constraints flow through the shared graph, so a
    # conflict surfaces even when each formula is internally consistent.
    def check_batch(formulas, types: nil, signatures: nil)
      run_batch(formulas, types: types, signatures: signatures, batch: true)
    end

    private

    def run_batch(formulas, types: nil, signatures: nil, batch: false)
      declared = declared_types(types)
      sigs = @signatures.merge(normalize_signatures(signatures || {}))
      unifier = Unifier.new
      serial = Serial.new

      asts = formulas.transform_values { |formula| parse(formula) }

      # global env: declared inputs plus a flex slot for each named formula
      formula_vars = asts.keys.to_h do |name|
        [standardize(name), Type.flex(serial.next_id)]
      end
      env = declared.merge(formula_vars)

      inferred_types = {}
      all_unknowns = []
      conflicts = []

      asts.each do |name, ast|
        analyzer = Analyzer.new(
          unifier: unifier,
          serial: serial,
          env: env,
          signatures: sigs,
          expression: formulas[name],
          formula_name: name
        )

        inferred =
          begin
            analyzer.check(ast)
          rescue TypeConflict => conflict
            conflicts << build_conflict(conflict, name, formulas[name])
            # keep the partial type so the reported result shows what the
            # expression claimed to be even when a sub-constraint disagreed
            conflict_partial(conflict)
          end

        all_unknowns.concat(analyzer.unknowns)

        begin
          unifier.unify(formula_vars.fetch(standardize(name)), inferred, [])
        rescue TypeConflict => conflict
          conflicts << build_conflict(conflict, name, formulas[name])
        end

        inferred_types[standardize(name)] = inferred
      end

      resolved_types = inferred_types.transform_values { |t| unifier.resolve(t) }
      attach_unknown_influence(all_unknowns, unifier)
      conflicts.uniq! { |c| [c.expected, c.actual, c.ranges] }

      Result.new(
        type: batch ? nil : resolved_types.values.first,
        types: resolved_types,
        conflicts: conflicts,
        unknowns: all_unknowns.uniq { |u| [u.name, u.range, u.formula] },
        expression: batch ? nil : formulas.values.first
      )
    end

    def parse(formula)
      if @calculator
        parse_with_calculator(formula)
      else
        tokens = Tokenizer.new.tokenize(formula)
        Parser.new(tokens, skip_type_checks: true).parse
      end
    end

    def parse_with_calculator(formula)
      return @calculator.ast(formula) if @calculator.ast_cache.key?(formula)

      options = {
        aliases: @calculator.aliases,
        case_sensitive: @calculator.case_sensitive,
        function_registry: @calculator.instance_variable_get(:@function_registry),
        raw_date_literals: @calculator.raw_date_literals,
        skip_type_checks: true
      }
      tokens = @calculator.tokenizer.tokenize(formula, options)
      Parser.new(tokens, options).parse
    end

    # after a conflict the two sides are usually concrete; prefer those for
    # the display type of the failed expression
    def conflict_partial(conflict)
      [conflict.left, conflict.right].find do |t|
        t.is_a?(Type::Scalar) || t.is_a?(Type::ArrayT)
      end || Type.any(:conflict, nil)
    end

    def declared_types(extra)
      merged = @declared_types.merge(extra || {})
      merged.transform_keys { |k| standardize(k) }
                   .transform_values { |v| coerce_type(v) }
    end

    def coerce_type(value)
      case value
      when Type::Scalar, Type::ArrayT, Type::Var, Type::Flex, Type::Any
        value
      when Symbol, String
        Type.parse(value.to_s)
      when ::Array
        Type.array(coerce_type(value.first))
      else
        raise TypeError, "cannot use #{value.inspect} as a declared type"
      end
    end

    def normalize_signatures(hash)
      hash.to_h do |name, spec|
        signature =
          case spec
          when Signature then spec
          when String then Signature.parse(spec)
          else
            raise TypeError, "function signature for #{name} must be a String or Signature"
          end
        [standardize(name), signature]
      end
    end

    def standardize(name)
      name.to_s.downcase
    end

    def build_conflict(conflict, formula_name, expression)
      message = ConflictMessages.new(conflict, expression).message
      Conflict.new(
        message: message,
        expected: Renderer.render(conflict.left),
        actual: Renderer.render(conflict.right),
        sites: conflict.sites,
        formula: formula_name
      )
    end

    def attach_unknown_influence(unknowns, unifier)
      unifier.unknowns.each do |entry|
        any = entry[:any]
        sites = entry[:sites]
        match = unknowns.find { |u| u.range == any.range }
        next unless match

        match.sites.concat(sites).uniq!(&:key)
      end
    end

    # builds a readable message annotated with source snippets/offsets
    class ConflictMessages
      def initialize(conflict, expression)
        @conflict = conflict
        @expression = expression
      end

      def message
        left = Renderer.render(@conflict.left)
        right = Renderer.render(@conflict.right)
        where = locations
        "cannot unify #{left} with #{right}" + (where.empty? ? "" : " at #{where.join('; ')}")
      end

      private

      def locations
        @conflict.sites.map do |site|
          label = site.label
          if site.range && @expression
            start, finish = site.range
            snippet = @expression[start...finish].to_s
            label ? "#{label} (#{snippet.inspect} @#{start})" : "#{snippet.inspect} @#{start}"
          else
            label
          end
        end.compact.uniq
      end
    end
  end
  end
end
