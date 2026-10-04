require 'set'
require 'dentaku/calculator'
require 'dentaku/source_location'

module Dentaku
  # Statically checks a formula against declared variable types and
  # function signatures, without evaluating anything. Definite type
  # conflicts (like adding a string to a date) surface at entry time
  # instead of waiting for a task run to hit the wrong branch.
  #
  #   result = Dentaku::TypeChecker.check(
  #     "IF(age >= 18, price * 0.9, start_date + name)",
  #     types: { age: :numeric, price: :numeric,
  #              start_date: :datetime, name: :string }
  #   )
  #   result.ok?     # => false
  #   result.issues  # => [#<Dentaku::TypeChecker::Issue ... 27...44>]
  #
  # Undeclared variables have "unknown" type: using them is not an
  # error, it just makes the inferred result type unknown as well.
  class TypeChecker
    # A type inferred for (part of) an expression. Kinds:
    #
    # - primitives: :numeric, :string, :logical, :datetime, :duration, :nil
    # - :array with an +element+ type
    # - :union of several member types (e.g. both branches of an IF)
    # - :unknown when the type cannot be determined statically
    class Type
      PRIMITIVES = %i[numeric string logical datetime duration nil].freeze

      attr_reader :kind, :element, :members

      def initialize(kind, element: nil, members: nil)
        @kind = kind
        @element = element
        @members = members
      end

      def self.[](kind)
        kind.to_sym == :unknown ? unknown : new(kind.to_sym)
      end

      def self.unknown
        @unknown ||= new(:unknown)
      end

      def self.array(element)
        new(:array, element: element)
      end

      def self.union(types)
        members = types.flat_map { |type| type.union? ? type.members : [type] }.uniq
        return unknown if members.empty?
        return members.first if members.one?

        new(:union, members: members.sort_by(&:to_s))
      end

      # Builds a type from a user-facing declaration:
      #
      #   :numeric, :string, :logical, :datetime, :duration, :nil, :unknown
      #   [:array, <decl>]         array with a known element type
      #   [:array] / :array        array with unknown elements
      #   [:union, <decl>, ...]    union of several types
      def self.from_declaration(decl)
        case decl
        when Type
          decl
        when ::Array
          tag, *rest = decl
          case tag.to_sym
          when :array
            rest.empty? ? array(unknown) : array(from_declaration(rest.first))
          when :union
            union(rest.map { |member| from_declaration(member) })
          else
            raise ::ArgumentError, "unknown type declaration: #{decl.inspect}"
          end
        when ::Symbol, ::String
          from_symbol(decl.to_sym)
        else
          raise ::ArgumentError, "unknown type declaration: #{decl.inspect}"
        end
      end

      def self.from_symbol(symbol)
        case symbol
        when :numeric, :integer, :float, :decimal then new(:numeric)
        when :string, :text then new(:string)
        when :logical, :boolean, :bool then new(:logical)
        when :datetime, :date, :time then new(:datetime)
        when :duration then new(:duration)
        when :nil, :null then new(:nil)
        when :array, :list then array(unknown)
        when :unknown, :any then unknown
        else
          raise ::ArgumentError, "unknown type: #{symbol.inspect}"
        end
      end

      def unknown?
        kind == :unknown
      end

      def union?
        kind == :union
      end

      def array?
        kind == :array
      end

      def each_member
        return enum_for(:each_member) unless block_given?

        union? ? members.each { |member| yield member } : yield(self)
      end

      def include_unknown?
        each_member.any?(&:unknown?)
      end

      def ==(other)
        other.is_a?(Type) &&
          kind == other.kind &&
          element == other.element &&
          members == other.members
      end
      alias_method :eql?, :==

      def hash
        [kind, element, members].hash
      end

      def to_s
        case kind
        when :unknown then "unknown"
        when :array   then "array<#{element}>"
        when :union   then members.map(&:to_s).join(" | ")
        else kind.to_s
        end
      end
      alias_method :inspect, :to_s
    end

    # A single type conflict, located in the original expression text.
    class Issue
      attr_reader :message, :loc

      def initialize(message, loc)
        @message = message
        @loc = loc
      end

      def offset
        loc&.offset
      end

      def length
        loc&.length
      end

      # the slice of the user's expression this issue points at
      def snippet(source)
        loc && loc.snippet(source)
      end

      def to_s
        loc ? "#{message} (at #{loc})" : message
      end
      alias_method :inspect, :to_s
    end

    # The outcome of a check: the inferred result type plus any definite
    # type conflicts found along the way.
    class Result
      attr_reader :type, :issues

      def initialize(type, issues)
        @type = type
        @issues = issues.freeze
      end

      def ok?
        issues.empty?
      end

      # true when the inferred type depends on undeclared variables
      def unknown?
        type.include_unknown?
      end

      def to_s
        ok? ? type.to_s : "#{type} with #{issues.length} issue(s)"
      end
      alias_method :inspect, :to_s
    end

    # A declared signature for a custom (or built-in) function:
    #
    #   { params: [:numeric, [:optional, :numeric]], returns: :numeric }
    #
    # A trailing [:rest, <decl>] param accepts any number of arguments.
    class Signature
      attr_reader :name, :params, :returns

      def self.from_declaration(name, decl)
        unless decl.is_a?(::Hash) && decl.key?(:params)
          raise ::ArgumentError, "invalid signature for #{name}: #{decl.inspect}"
        end

        new(name, decl[:params], decl[:returns] || decl[:return] || :unknown)
      end

      def initialize(name, params, returns)
        @name = name
        @params = params.map { |param| Param.new(param) }
        @returns = Type.from_declaration(returns)
      end

      # :clean when every argument definitely matches, :tainted when the
      # match depends on unknown argument types, nil when it cannot match
      def match(arg_types)
        args = arg_types.dup
        tainted = false

        params.each do |param|
          if param.rest?
            args.each do |arg|
              result = param.match_one(arg)
              return nil if result.nil?

              tainted ||= result == :tainted
            end
            args.clear
          else
            arg = args.shift
            if arg.nil?
              return nil unless param.optional?
            else
              result = param.match_one(arg)
              return nil if result.nil?

              tainted ||= result == :tainted
            end
          end
        end

        return nil unless args.empty?

        tainted ? :tainted : :clean
      end

      def to_s
        "#{name}(#{params.map(&:to_s).join(', ')}) -> #{returns}"
      end

      # One parameter constraint inside a signature.
      class Param
        attr_reader :constraint, :modifier

        def initialize(decl)
          if decl.is_a?(::Array) && %i[rest optional].include?(decl.first)
            @modifier = decl.first
            @constraint = Type.from_declaration(decl[1] || :any)
          elsif decl == :any
            @modifier = nil
            @constraint = Type.unknown
          else
            @modifier = nil
            @constraint = Type.from_declaration(decl)
          end
        end

        def rest?
          modifier == :rest
        end

        def optional?
          modifier == :optional
        end

        # :clean / :tainted / nil for a single argument type
        def match_one(arg_type)
          return :clean if constraint.unknown?

          tainted = false
          arg_type.each_member do |member|
            if member.unknown?
              tainted = true
            elsif !member_matches?(member)
              return nil
            end
          end
          tainted ? :tainted : :clean
        end

        def to_s
          case modifier
          when :rest     then "*#{constraint}"
          when :optional then "#{constraint}?"
          else constraint.to_s
          end
        end

        private

        def member_matches?(member)
          return constraint.members.any? { |option| constraint_matches?(option, member) } if constraint.union?

          constraint_matches?(constraint, member)
        end

        def constraint_matches?(constraint, member)
          return true if constraint.unknown?

          if constraint.array?
            member.array? && element_matches?(constraint, member.element)
          else
            constraint.kind == member.kind
          end
        end

        def element_matches?(constraint, element_type)
          !Param.new(constraint.element || :any).match_one(element_type).nil?
        end
      end
    end

    NUMERIC_OR_LIST = [:union, :numeric, [:array, :numeric]].freeze
    COMPARABLE = %i[numeric string datetime].freeze

    # signatures for functions built into Dentaku itself; custom functions
    # participate through the +functions:+ option instead
    BUILTIN_SIGNATURES = {
      "abs"        => [{ params: [:numeric], returns: :numeric }],
      "round"      => [{ params: [:numeric, [:optional, :numeric]], returns: :numeric }],
      "roundup"    => [{ params: [:numeric, [:optional, :numeric]], returns: :numeric }],
      "rounddown"  => [{ params: [:numeric, [:optional, :numeric]], returns: :numeric }],
      "not"        => [{ params: [:logical], returns: :logical }],
      "and"        => [{ params: [[:rest, :logical]], returns: :logical }],
      "or"         => [{ params: [[:rest, :logical]], returns: :logical }],
      "xor"        => [{ params: [[:rest, :logical]], returns: :logical }],
      "min"        => [{ params: [[:rest, NUMERIC_OR_LIST]], returns: :numeric }],
      "max"        => [{ params: [[:rest, NUMERIC_OR_LIST]], returns: :numeric }],
      "sum"        => [{ params: [[:rest, NUMERIC_OR_LIST]], returns: :numeric }],
      "avg"        => [{ params: [[:rest, NUMERIC_OR_LIST]], returns: :numeric }],
      "mul"        => [{ params: [[:rest, NUMERIC_OR_LIST]], returns: :numeric }],
      "count"      => [{ params: [[:rest, :any]], returns: :numeric }],
      "left"       => [{ params: [:string, :numeric], returns: :string }],
      "right"      => [{ params: [:string, :numeric], returns: :string }],
      "mid"        => [{ params: [:string, :numeric, :numeric], returns: :string }],
      "len"        => [{ params: [:string], returns: :numeric }],
      "find"       => [{ params: [:string, :string], returns: :numeric }],
      "substitute" => [{ params: [:string, :string, :string], returns: :string }],
      "concat"     => [{ params: [[:rest, :any]], returns: :string }],
      "contains"   => [{ params: [:string, :string], returns: :logical }],
      "intercept"  => [{ params: [[:array, :numeric], [:array, :numeric]], returns: :numeric }],
      "duration"   => [{ params: [:numeric, :any], returns: :duration }],
    }.freeze

    attr_reader :issues

    def self.check(expression, **options)
      new(**options).check(expression)
    end

    def initialize(types: {}, functions: {}, calculator: nil)
      @calculator = calculator || Calculator.new
      @case_sensitive = @calculator.case_sensitive
      @declared_types = types.each_with_object({}) do |(name, decl), memo|
        memo[normalize(name)] = Type.from_declaration(decl)
      end
      @signatures = functions.each_with_object({}) do |(name, decls), memo|
        memo[name.to_s.downcase] = Array(decls).map do |decl|
          Signature.from_declaration(name, decl)
        end
      end
      @signatures.each_key { |name| ensure_function_registered(name) }
      @issues = []
      @seen = Set.new
    end

    def check(expression)
      ast = expression.is_a?(AST::Node) ? expression : @calculator.ast(expression)
      Result.new(check_node(ast, {}), issues)
    end

    private

    # Declared signatures must parse, so a name the calculator does not
    # know gets a check-only stub. The stub is volatile and raises when
    # evaluated: the checker itself never calls functions.
    def ensure_function_registered(name)
      return if @calculator.function_registry.get(name)

      @calculator.add_function(
        name, :unknown,
        ->(*_args) {
          raise Dentaku::BaseError,
                "#{name}() was declared for static checking only and cannot be evaluated"
        },
        volatile: true
      )
    end

    def normalize(name)
      @case_sensitive ? name.to_s : name.to_s.downcase
    end

    def check_node(node, env)
      case node
      when AST::Negation, AST::Percentage
        check_unary_numeric(node, env)
      when AST::Addition, AST::Subtraction
        check_additive(node, env)
      when AST::Multiplication, AST::Division, AST::Modulo,
           AST::Exponentiation, AST::Bitwise
        check_binary_numeric(node, env)
      when AST::Equal, AST::NotEqual
        check_equality(node, env)
      when AST::Comparator
        check_comparator(node, env)
      when AST::Combinator
        check_logical_operands(node, env)
      when AST::If
        check_if(node, env)
      when AST::Case
        check_case(node, env)
      when AST::Map
        check_enum(node, env, :map)
      when AST::Filter
        check_enum(node, env, :filter)
      when AST::All, AST::Any
        check_enum(node, env, :logical)
      when AST::Pluck
        check_pluck(node, env)
      when AST::Reduce
        check_reduce(node, env)
      when AST::RubyMath
        check_ruby_math(node, env)
      when AST::Access
        check_access(node, env)
      when AST::Array
        check_array(node, env)
      when AST::Identifier
        check_identifier(node, env)
      when AST::Literal
        Type[node.type]
      when AST::Nil
        Type[:nil]
      when AST::Grouping
        check_node(node.node, env)
      when AST::Function
        check_function(node, env)
      else
        Type.unknown
      end
    end

    def check_identifier(node, env)
      name = node.identifier
      return env[name] if env.key?(name)
      return @declared_types[name] if @declared_types.key?(name)

      local, = name.split(".", 2)
      if local != name && env.key?(local)
        type = env[local]
        unless type.include_unknown?
          add_issue(%("#{name}" accesses a field of "#{local}", which is #{type}), node)
        end
        return Type.unknown
      end

      Type.unknown
    end

    def check_unary_numeric(node, env)
      operand = node.is_a?(AST::Negation) ? node.node : node.left
      type = check_node(operand, env)
      require_members(type, %i[numeric], operand, "operand")
      with_unknown(type) { Type[:numeric] }
    end

    def check_additive(node, env)
      operator = node.display_operator
      subtraction = node.is_a?(AST::Subtraction)
      left = check_node(node.left, env)
      right = check_node(node.right, env)
      allowed_left = %i[numeric datetime]
      allowed_right = %i[numeric datetime duration]

      require_members(left, allowed_left, node.left, "left operand of #{operator}")
      require_members(right, allowed_right, node.right, "right operand of #{operator}")

      results = []
      left.each_member do |l|
        right.each_member do |r|
          if l.unknown? || r.unknown?
            results << Type.unknown
          elsif (kind = additive_result(subtraction, l.kind, r.kind))
            results << Type[kind]
          elsif allowed_left.include?(l.kind) && allowed_right.include?(r.kind)
            add_issue("#{l} #{operator} #{r} is not supported", node)
          end
        end
      end

      Type.union(results)
    end

    def additive_result(subtraction, left_kind, right_kind)
      return :numeric if left_kind == :numeric && right_kind == :numeric
      return nil unless left_kind == :datetime

      case right_kind
      when :numeric, :duration then :datetime
      when :datetime then subtraction ? :numeric : nil
      end
    end

    def check_binary_numeric(node, env)
      operator = node.display_operator
      left = check_node(node.left, env)
      right = check_node(node.right, env)
      require_members(left, %i[numeric], node.left, "left operand of #{operator}")
      require_members(right, %i[numeric], node.right, "right operand of #{operator}")
      with_unknown(left, right) { Type[:numeric] }
    end

    def check_equality(node, env)
      check_node(node.left, env)
      check_node(node.right, env)
      Type[:logical]
    end

    def check_comparator(node, env)
      operator = node.display_operator
      left = check_node(node.left, env)
      right = check_node(node.right, env)
      require_members(left, COMPARABLE, node.left, "left operand of #{operator}")
      require_members(right, COMPARABLE, node.right, "right operand of #{operator}")

      left.each_member do |l|
        right.each_member do |r|
          next if l.unknown? || r.unknown?
          next unless COMPARABLE.include?(l.kind) && COMPARABLE.include?(r.kind)

          add_issue("cannot compare #{l} with #{r}", node) if l.kind != r.kind
        end
      end

      Type[:logical]
    end

    def check_logical_operands(node, env)
      operator = node.display_operator
      left = check_node(node.left, env)
      right = check_node(node.right, env)
      require_members(left, %i[logical], node.left, "left operand of #{operator}")
      require_members(right, %i[logical], node.right, "right operand of #{operator}")
      with_unknown(left, right) { Type[:logical] }
    end

    def check_if(node, env)
      predicate = check_node(node.predicate, env)
      require_members(predicate, %i[logical], node.predicate, "IF condition")
      Type.union([check_node(node.left, env), check_node(node.right, env)])
    end

    def check_case(node, env)
      switch_type = check_node(node.switch.node, env)
      branch_types = node.conditions.map do |condition|
        when_type = check_node(condition.when.node, env)
        check_case_match(switch_type, when_type, condition.when.node)
        check_node(condition.then.node, env)
      end
      branch_types << check_node(node.else.node, env) if node.else
      Type.union(branch_types)
    end

    def check_case_match(switch_type, when_type, node)
      switch_type.each_member do |switch|
        when_type.each_member do |option|
          next if switch.unknown? || option.unknown?
          next if switch.kind == option.kind

          add_issue("CASE value of type #{switch} can never match WHEN #{option}", node)
        end
      end
    end

    def check_enum(node, env, kind)
      collection = check_node(node.args[0], env)
      element = collection_element_type(collection, node.args[0])
      local = node.args[1].identifier
      body = check_node(node.args[2], env.merge(local => element))

      case kind
      when :map
        Type.array(body)
      when :filter, :logical
        label = "#{function_name(node).upcase} expression"
        require_members(body, %i[logical], node.args[2], label)
        kind == :filter ? Type.array(element) : Type[:logical]
      end
    end

    def check_pluck(node, env)
      collection = check_node(node.args[0], env)
      collection_element_type(collection, node.args[0])
      check_node(node.args[2], env) if node.args[2]
      Type.array(Type.unknown)
    end

    def check_reduce(node, env)
      collection = check_node(node.args[0], env)
      element = collection_element_type(collection, node.args[0])
      memo = node.args[4] ? check_node(node.args[4], env) : element
      body_env = env.merge(
        node.args[1].identifier => memo,
        node.args[2].identifier => element
      )
      check_node(node.args[3], body_env)
    end

    def check_ruby_math(node, env)
      node.args.each do |arg|
        type = check_node(arg, env)
        require_members(type, %i[numeric], arg, "argument of #{function_name(node).upcase}")
      end
      Type[:numeric]
    end

    def check_access(node, env)
      structure = check_node(node.structure, env)
      index = check_node(node.index, env)
      require_members(index, %i[numeric string], node.index, "index")

      results = []
      structure.each_member do |member|
        case member.kind
        when :unknown then results << Type.unknown
        when :array   then results << member.element
        when :string  then results << Type[:string]
        else add_issue("cannot index into #{member}", node.structure)
        end
      end
      Type.union(results)
    end

    def check_array(node, env)
      Type.array(Type.union(node.elements.map { |element| check_node(element, env) }))
    end

    def check_function(node, env)
      arg_types = node.args.map { |arg| check_node(arg, env) }
      name = function_name(node)

      if (signatures = @signatures[name])
        return resolve_signature(name, signatures, arg_types, node)
      end

      return check_switch(arg_types) if name == "switch"

      if (signatures = builtin_signatures(name))
        return resolve_signature(name, signatures, arg_types, node)
      end

      registered_return_type(node)
    end

    def check_switch(arg_types)
      return Type.unknown if arg_types.length < 2

      Type.union(arg_types[1..-1].each_slice(2).map(&:last))
    end

    def resolve_signature(name, signatures, arg_types, node)
      matches = signatures.filter_map do |signature|
        state = signature.match(arg_types)
        [signature, state] if state
      end

      clean = matches.select { |_, state| state == :clean }
      candidates = clean.any? ? clean : matches

      if candidates.empty?
        add_issue(
          "no matching signature for #{name}(#{arg_types.map(&:to_s).join(', ')}); " +          "declared: #{signatures.map(&:to_s).join('; ')}",
          node
        )
        return Type.unknown
      end

      returns = candidates.map { |signature, _| signature.returns }.uniq
      if returns.length > 1 && clean.any?
        add_issue(
          "ambiguous call to #{name}(#{arg_types.map(&:to_s).join(', ')}): matches " +          "#{candidates.map { |signature, _| signature.to_s }.join(' and ')}",
          node
        )
      end

      Type.union(returns)
    end

    def builtin_signatures(name)
      decls = BUILTIN_SIGNATURES[name]
      return nil unless decls

      decls.map { |decl| Signature.from_declaration(name, decl) }
    end

    # a custom function registered without declared signatures still
    # contributes its registered return type; it is never called
    def registered_return_type(node)
      type = node.class.respond_to?(:type) ? node.class.type : nil
      type ? Type.from_declaration(type) : Type.unknown
    rescue ::ArgumentError
      Type.unknown
    end

    def collection_element_type(type, node)
      elements = []
      type.each_member do |member|
        case member.kind
        when :unknown then elements << Type.unknown
        when :array   then elements << member.element
        else add_issue("expected an array, got #{member}", node)
        end
      end
      Type.union(elements)
    end

    def require_members(type, allowed, node, label)
      type.each_member do |member|
        next if member.unknown?
        next if allowed.include?(member.kind)

        add_issue("#{label} must be #{allowed.join(' or ')}, got #{member}", node)
      end
    end

    def with_unknown(*types)
      result = yield
      types.any?(&:include_unknown?) ? Type.union([result, Type.unknown]) : result
    end

    def function_name(node)
      node.class.name.to_s.split("::").last.to_s.downcase
    end

    def add_issue(message, node)
      loc = node.respond_to?(:loc) ? node.loc : nil
      key = [message, loc]
      return if @seen.include?(key)

      @seen << key
      @issues << Issue.new(message, loc)
    end
  end
end
