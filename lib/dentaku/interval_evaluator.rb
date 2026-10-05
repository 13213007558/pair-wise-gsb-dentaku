require_relative 'interval'
require_relative 'interval_result'

module Dentaku
  # Evaluates a parsed Dentaku expression over interval-valued inputs.
  #
  # Numeric subexpressions always yield an IntervalResult; predicates yield
  # one of the tri-state symbols :true / :false / :unknown. Every numeric
  # result is a sound enclosure: it contains every value the expression can
  # attain for admissible inputs, at the cost of possible overestimation.
  class IntervalEvaluator
    TRUE = :true
    FALSE = :false
    UNKNOWN = :unknown

    EXPONENT_ENUMERATION_LIMIT = 64

    def initialize(interval_rules: nil, precision: 16)
      @interval_rules = interval_rules || {}
      @precision = precision
    end

    def evaluate(node, context)
      raw = visit(node, context)
      raw = assert_numeric!(raw, node)
      interval, moved = raw.interval.round_outward(@precision)
      if moved
        note = IntervalResult.note(
          :outward_rounding,
          "endpoints rounded outward to #{@precision} significant digits"
        )
        raw = raw.with_notes(note)
      end
      IntervalResult.new(interval, notes: raw.notes, undefined_points: raw.undefined_points)
    end

    private

    def visit(node, context)
      case node
      when AST::Grouping
        visit(node.instance_variable_get(:@node), context)
      when AST::Numeric
        exact(Interval.point(normalize_scalar(node.value)))
      when AST::Logical
        node.value(context) ? TRUE : FALSE
      when AST::Identifier
        visit_identifier(node, context)
      when AST::Negation
        assert_numeric!(visit(node.node, context), node).map_interval(&:neg)
      when AST::Percentage
        assert_numeric!(visit(node.instance_variable_get(:@left), context), node)
          .scale(Rational(1, 100))
      when AST::Addition
        combine_numeric(node, context) { |a, b| a.add(b) }
      when AST::Subtraction
        combine_numeric(node, context) { |a, b| a.sub(b) }
      when AST::Multiplication
        combine_numeric(node, context) { |a, b| a.mul(b) }
      when AST::Division
        visit_division(node, context)
      when AST::Exponentiation
        visit_power(node, context)
      when AST::Modulo
        unsupported(node, "modulo has no interval rule")
      when AST::LessThan, AST::LessThanOrEqual, AST::GreaterThan,
           AST::GreaterThanOrEqual, AST::Equal, AST::NotEqual
        visit_comparator(node, context)
      when AST::And
        visit_and(node, context)
      when AST::Or
        visit_or(node, context)
      when AST::If
        visit_if(node, context)
      when AST::Array
        node.instance_variable_get(:@elements).map { |element| visit(element, context) }
      else
        visit_function(node, context)
      end
    end

    def visit_identifier(node, context)
      value = context.fetch(node.identifier) do
        raise UnboundVariableError.new([node.identifier]),
              "no value provided for variables: #{node.identifier}"
      end
      coerce_value(value, context, node.identifier)
    end

    def coerce_value(value, context, name)
      case value
      when IntervalResult then value
      when Interval then exact(value)
      when true, FALSE then value ? TRUE : FALSE
      when ::Integer, ::Rational, ::BigDecimal, ::Float
        exact(Interval.point(normalize_scalar(value)))
      when Node
        visit(value, context)
      when Proc
        coerce_value(value.call, context, name)
      else
        raise Dentaku::ArgumentError.for(
          :incompatible_type, actual: value.class, expected: Interval
        ), "interval evaluation needs numeric or boolean input for '#{name}'"
      end
    end

    def combine_numeric(node, context)
      left = assert_numeric!(visit(node.left, context), node.left)
      right = assert_numeric!(visit(node.right, context), node.right)
      merge_metadata(exact(yield(left.interval, right.interval)), left, right)
    end

    def visit_division(node, context)
      left = assert_numeric!(visit(node.left, context), node.left)
      right = assert_numeric!(visit(node.right, context), node.right)
      image, undefined = left.interval.div(right.interval)
      result = exact(image)
      result = result.with_undefined(undefined) unless undefined.empty?
      if image.unbounded?
        result = result.with_notes(IntervalResult.note(
          :unbounded_result,
          "divisor #{right.interval} crosses or touches zero: the image is unbounded, " \
          "and the zero divisor itself stays undefined"
        ))
      end
      merge_metadata(result, left, right)
    end

    def visit_power(node, context)
      base = assert_numeric!(visit(node.left, context), node.left)
      exponent = assert_numeric!(visit(node.right, context), node.right)
      unless integer_interval?(exponent.interval)
        return merge_metadata(unsupported(node, "only integer exponents have interval rules"), base, exponent)
      end

      low_exponent = exponent.interval.low.to_i
      high_exponent = exponent.interval.high.to_i
      result = if exponent.interval.degenerate?
                 single_power(base.interval, low_exponent)
               elsif low_exponent >= 0 && (high_exponent - low_exponent + 1) <= EXPONENT_ENUMERATION_LIMIT
                 (low_exponent..high_exponent)
                   .map { |power| single_power(base.interval, power) }
                   .reduce { |acc, item| acc.merge(item) }
               else
                 unsupported(node, "exponent interval #{exponent.interval} is too wide to enumerate")
               end
      merge_metadata(result, base, exponent)
    end

    def single_power(base, exponent)
      image, undefined = base.ipow(exponent)
      result = exact(image)
      result = result.with_undefined(undefined) unless undefined.empty?
      result
    end

    def visit_comparator(node, context)
      left = assert_numeric!(visit(node.left, context), node.left)
      right = assert_numeric!(visit(node.right, context), node.right)
      compare(node.operator, left.interval, right.interval)
    end

    def compare(operator, left, right)
      definitely = case operator
                   when :< then left.high < right.low
                   when :<= then left.high <= right.low
                   when :> then left.low > right.high
                   when :>= then left.low >= right.high
                   when :== then left.point? && right.point? && left.low == right.low
                   when :!= then !overlap?(left, right)
                   end
      possibly = case operator
                 when :< then left.low < right.high
                 when :<= then left.low <= right.high
                 when :> then left.high > right.low
                 when :>= then left.high >= right.low
                 when :== then overlap?(left, right)
                 when :!= then !(left.point? && right.point? && left.low == right.low)
                 end
      definitely ? TRUE : (possibly ? UNKNOWN : FALSE)
    end

    def overlap?(left, right)
      left.low <= right.high && right.low <= left.high
    end

    def visit_and(node, context)
      left = visit(node.left, context)
      return FALSE if left == FALSE
      return left if left == TRUE

      right = visit(node.right, context)
      return FALSE if right == FALSE
      return TRUE if left == TRUE && right == TRUE

      UNKNOWN
    end

    def visit_or(node, context)
      left = visit(node.left, context)
      return TRUE if left == TRUE
      return left if left == FALSE

      right = visit(node.right, context)
      return TRUE if right == TRUE
      return FALSE if left == FALSE && right == FALSE

      UNKNOWN
    end

    def visit_if(node, context)
      outcome = visit(node.predicate, context)
      case outcome
      when TRUE then visit(node.left, context)
      when FALSE then visit(node.right, context)
      else
        truthy = assert_numeric!(visit(node.left, context), node.left)
        falsy = assert_numeric!(visit(node.right, context), node.right)
        truthy.merge(falsy, IntervalResult.note(
          :indeterminate_branch,
          "predicate could be neither proved true nor false; feasible IF branches were merged",
          location: "IF##{node.object_id}"
        ))
      end
    end

    def visit_function(node, context)
      name = function_name(node)
      case name
      when 'not' then visit_not(node, context)
      when 'abs' then visit_abs(node, context)
      when 'min', 'max' then visit_minmax(name, node, context)
      else
        rule = @interval_rules[name]
        rule ? invoke_rule(rule, node, context) : unknown_function(name, node, context)
      end
    end

    def visit_not(node, context)
      case visit(node.args.first, context)
      when TRUE then FALSE
      when FALSE then TRUE
      else UNKNOWN
      end
    end

    def visit_abs(node, context)
      operand = flatten_arguments(node, context).first
      operand.map_interval(&:abs)
    end

    def visit_minmax(name, node, context)
      arguments = flatten_arguments(node, context)
      intervals = arguments.map(&:interval)
      image = if name == 'min'
                Interval.new(intervals.map(&:low).min, intervals.map(&:high).min)
              else
                Interval.new(intervals.map(&:low).max, intervals.map(&:high).max)
              end
      merge_metadata(exact(image), *arguments)
    end

    def invoke_rule(rule, node, context)
      arguments = flatten_arguments(node, context)
      returned = rule.call(*arguments.map(&:interval))
      returned = returned.interval if returned.is_a?(IntervalResult)
      unless returned.is_a?(Interval)
        raise Dentaku::ArgumentError.for(:invalid_value, actual: returned.class),
              "interval function rules must return a Dentaku::Interval"
      end
      merge_metadata(exact(returned), *arguments)
    end

    def unknown_function(name, node, context)
      arguments = node.args.map do |arg|
        begin
          visit(arg, context)
        rescue Dentaku::Error
          nil
        end
      end.flat_map { |value| value.is_a?(::Array) ? value : [value] }.grep(IntervalResult)

      result = exact(Interval::UNIVERSE).with_notes(IntervalResult.note(
        :unknown_function_rule,
        "no interval rule registered for '#{name}'; result widened to the full extended-real line"
      ))
      merge_metadata(result, *arguments)
    end

    def flatten_arguments(node, context)
      evaluated = node.args.map { |arg| visit(arg, context) }
      evaluated.flat_map do |value|
        value.is_a?(::Array) ? value.map { |item| assert_numeric!(item, node) } : [assert_numeric!(value, node)]
      end
    end

    def unsupported(node, message)
      exact(Interval::UNIVERSE).with_notes(IntervalResult.note(
        :unsupported_operation, message, location: node.class.name.to_s
      ))
    end

    def merge_metadata(result, *others)
      others.compact.each do |other|
        next unless other.is_a?(IntervalResult)

        result = result.with_notes(*other.notes)
        result = result.with_undefined(other.undefined_points)
      end
      result
    end

    def assert_numeric!(value, node)
      return value if value.is_a?(IntervalResult)

      actual = value.is_a?(Symbol) ? :logical : value.class
      raise Dentaku::ArgumentError.for(:incompatible_type, actual: actual, expected: :numeric),
            "numeric value required while evaluating #{node.class.name}"
    end

    def exact(interval)
      IntervalResult.new(interval)
    end

    def normalize_scalar(value)
      case value
      when ::Integer then value
      when ::Rational then value
      when ::BigDecimal then value.to_r
      when ::Float then value.infinite? ? value : Rational(value, Float::DIG + 1)
      else value
      end
    end

    def integer_interval?(interval)
      return true if interval.degenerate? && integer_value?(interval.low)

      [interval.low, interval.high].all? { |value| integer_value?(value) }
    end

    def integer_value?(value)
      value.is_a?(::Integer) ||
        (value.is_a?(::Rational) && value.denominator == 1) ||
        (value.is_a?(::BigDecimal) && value.frac.zero?)
    end

    def function_name(node)
      node.class.name.to_s.downcase
    rescue StandardError
      node.class.to_s.downcase
    end
  end
end
