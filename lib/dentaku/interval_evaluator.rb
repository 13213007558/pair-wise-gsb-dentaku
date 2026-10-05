require "dentaku/interval"

module Dentaku
  # Evaluates a Dentaku AST over interval-valued inputs, returning an
  # IntervalResult whose interval contains every value the expression can
  # take for any choice of inputs inside their intervals. The result is
  # allowed to be conservative (dependency correlations and merged branches
  # widen it) but never misses a legal value; every place where the answer
  # was widened is reported in IntervalResult#relaxations, and points where
  # the expression is undefined (e.g. a divisor that can be zero) are
  # reported in IntervalResult#undefined.
  #
  # Functions (built-in or custom) only participate in this mode when an
  # interval rule is registered for them; anything else widens to an
  # unbounded interval with an :unknown_rule relaxation.
  class IntervalEvaluator
    # tri-state truth values used for comparisons and logical nodes
    TRUE = :true
    FALSE = :false
    INDETERMINATE = :indeterminate

    # A recorded widening of the result. +kind+ is one of :branch_merge,
    # :unknown_rule, :division_by_zero, :unsupported_operation, or
    # :unsupported_node; +message+ describes where and why.
    Relaxation = Struct.new(:kind, :message)

    class Result
      attr_reader :value, :undefined, :relaxations

      def initialize(value, undefined: [], relaxations: [])
        @value = value
        @undefined = undefined
        @relaxations = relaxations
      end

      # the resulting Interval, or nil when the expression is logical
      def interval
        value.is_a?(Interval) ? value : nil
      end

      # tri-state truth value (:true / :false / :indeterminate) when the
      # expression is logical, nil otherwise
      def logical
        value.is_a?(Interval) ? nil : value
      end

      def relaxed?
        relaxations.any?
      end

      def undefined?
        undefined.any?
      end

      def unbounded?
        interval ? interval.unbounded? : false
      end

      def include?(number)
        interval ? interval.contains?(number) : false
      end

      def to_s
        parts = [value.to_s]
        parts << "undefined at " + undefined.map(&:to_s).join(", ") if undefined?
        parts << "relaxations: " + relaxations.map(&:kind).uniq.join(", ") if relaxed?
        parts.join(" (")
      end

      def inspect
        "#<Dentaku::IntervalEvaluator::Result " + to_s + ">"
      end
    end

    def self.kleene_and(*args)
      return FALSE if args.include?(FALSE)
      return TRUE if args.all? { |arg| arg == TRUE }

      INDETERMINATE
    end

    def self.kleene_or(*args)
      return TRUE if args.include?(TRUE)
      return FALSE if args.all? { |arg| arg == FALSE }

      INDETERMINATE
    end

    def self.kleene_not(arg)
      case arg
      when TRUE then FALSE
      when FALSE then TRUE
      else INDETERMINATE
      end
    end

    # Interval rules for the functions that ship with Dentaku. A rule
    # receives the evaluated arguments (Intervals for numeric arguments,
    # tri-state symbols for logical ones) and returns an Interval or a
    # tri-state symbol.
    DEFAULT_RULES = {
      "min" => ->(*args) { args.flatten.reduce { |acc, arg| acc.min(arg) } },
      "max" => ->(*args) { args.flatten.reduce { |acc, arg| acc.max(arg) } },
      "abs" => ->(x) { x.abs },
      "and" => ->(*args) { IntervalEvaluator.kleene_and(*args) },
      "or" => ->(*args) { IntervalEvaluator.kleene_or(*args) },
      "not" => ->(x) { IntervalEvaluator.kleene_not(x) }
    }.freeze

    # Registers a process-wide interval rule for a function name, so custom
    # functions can participate in interval evaluation. Rules registered
    # here apply to every IntervalEvaluator; prefer
    # Calculator#add_interval_rule for calculator-scoped rules.
    def self.register_rule(name, &block)
      custom_rules[name.to_s.downcase] = block
    end

    def self.custom_rules
      @custom_rules ||= {}
    end

    def initialize(rules: {})
      @rules = DEFAULT_RULES
        .merge(self.class.custom_rules)
        .merge(rules.transform_keys { |name| name.to_s.downcase })
    end

    # Walks +node+ (a Dentaku::AST::Node) with interval-valued +context+ and
    # returns an IntervalResult. Context values may be Interval, Numeric,
    # Range, [lo, hi] arrays, Procs returning any of those, or AST nodes
    # (shared variables defined by other expressions).
    def evaluate(node, context = {})
      relaxations = []
      undefined = []
      value = walk(node, context, relaxations, undefined)
      Result.new(value, undefined: undefined, relaxations: relaxations)
    end

    private

    attr_reader :rules

    def walk(node, context, relaxations, undefined)
      case node
      when AST::Numeric
        Interval.point(node.value)
      when AST::Logical
        node.value ? TRUE : FALSE
      when AST::Identifier
        walk_identifier(node, context, relaxations, undefined)
      when AST::Negation
        -walk(node.node, context, relaxations, undefined)
      when AST::Addition
        walk_binary(node, context, relaxations, undefined, :+)
      when AST::Subtraction
        walk_binary(node, context, relaxations, undefined, :-)
      when AST::Multiplication
        walk_binary(node, context, relaxations, undefined, :*)
      when AST::Division
        walk_division(node, context, relaxations, undefined)
      when AST::Percentage
        walk(node.left, context, relaxations, undefined) / Interval.point(100)
      when AST::Exponentiation
        walk_exponentiation(node, context, relaxations, undefined)
      when AST::LessThan
        walk_binary(node, context, relaxations, undefined, :lt)
      when AST::LessThanOrEqual
        walk_binary(node, context, relaxations, undefined, :le)
      when AST::GreaterThan
        walk_binary(node, context, relaxations, undefined, :gt)
      when AST::GreaterThanOrEqual
        walk_binary(node, context, relaxations, undefined, :ge)
      when AST::Equal
        walk_binary(node, context, relaxations, undefined, :eq)
      when AST::NotEqual
        walk_binary(node, context, relaxations, undefined, :ne)
      when AST::And
        IntervalEvaluator.kleene_and(
          walk(node.left, context, relaxations, undefined),
          walk(node.right, context, relaxations, undefined)
        )
      when AST::Or
        IntervalEvaluator.kleene_or(
          walk(node.left, context, relaxations, undefined),
          walk(node.right, context, relaxations, undefined)
        )
      when AST::If
        walk_if(node, context, relaxations, undefined)
      when AST::Function
        walk_function(node, context, relaxations, undefined)
      else
        relaxations << Relaxation.new(
          :unsupported_node,
          "no interval semantics for " + node.class.name + "; widening to unbounded"
        )
        Interval.unbounded
      end
    end

    def walk_identifier(node, context, relaxations, undefined)
      value = context.fetch(node.identifier) do
        raise UnboundVariableError.new([node.identifier]),
              "no value provided for variables: " + node.identifier
      end

      case value
      when Interval
        value
      when AST::Node
        walk(value, context, relaxations, undefined)
      when Proc
        Interval.from(value.call)
      else
        Interval.from(value)
      end
    rescue ::ArgumentError
      relaxations << Relaxation.new(
        :unsupported_node,
        "value of '" + node.identifier + "' is not interval-coercible; widening to unbounded"
      )
      Interval.unbounded
    end

    def walk_binary(node, context, relaxations, undefined, operator)
      left = walk(node.left, context, relaxations, undefined)
      right = walk(node.right, context, relaxations, undefined)
      left.public_send(operator, right)
    end

    def walk_division(node, context, relaxations, undefined)
      left = walk(node.left, context, relaxations, undefined)
      right = walk(node.right, context, relaxations, undefined)
      mark_zero_divisor(right, relaxations, undefined) if right.includes_zero?
      left / right
    end

    def mark_zero_divisor(divisor, relaxations, undefined)
      undefined << Interval.point(0.0)
      relaxations << Relaxation.new(
        :division_by_zero,
        "divisor " + divisor.to_s + " includes 0: result is unbounded and " \
          "the expression is undefined where the divisor is exactly 0"
      )
    end

    def walk_exponentiation(node, context, relaxations, undefined)
      base = walk(node.left, context, relaxations, undefined)
      exponent = walk(node.right, context, relaxations, undefined)

      unless exponent.point?
        relaxations << Relaxation.new(
          :unsupported_operation,
          "exponent " + exponent.to_s + " is not a single value; widening to unbounded"
        )
        return Interval.unbounded
      end

      power = exponent.lo
      return integer_power(base, power.to_i, relaxations, undefined) if power == power.to_i

      real_power(base, power, relaxations, undefined)
    end

    def integer_power(base, n, relaxations, undefined)
      if n.negative? && base.includes_zero?
        undefined << Interval.point(0.0)
        relaxations << Relaxation.new(
          :division_by_zero,
          "base " + base.to_s + " includes 0 with a negative exponent: result is " \
            "unbounded and the expression is undefined where the base is exactly 0"
        )
      end

      base**n
    end

    def real_power(base, power, relaxations, undefined)
      if base.lo >= 0.0 && power.positive?
        Interval.new(
          Interval.widen_lo(base.lo**power),
          Interval.widen_hi(base.hi**power)
        )
      elsif base.lo > 0.0
        Interval.new(
          Interval.widen_lo(base.hi**power),
          Interval.widen_hi(base.lo**power)
        )
      else
        relaxations << Relaxation.new(
          :unsupported_operation,
          "non-integer exponent " + power.to_s + " with base " + base.to_s + \
          " reaching below 0; widening to unbounded"
        )
        Interval.unbounded
      end
    end

    def walk_if(node, context, relaxations, undefined)
      case walk(node.predicate, context, relaxations, undefined)
      when TRUE
        walk(node.left, context, relaxations, undefined)
      when FALSE
        walk(node.right, context, relaxations, undefined)
      else
        then_value = walk(node.left, context, relaxations, undefined)
        else_value = walk(node.right, context, relaxations, undefined)
        relaxations << Relaxation.new(
          :branch_merge,
          "condition is indeterminate over the input intervals; " \
            "merging the then and else branches"
        )
        merge_branches(then_value, else_value, relaxations)
      end
    end

    def merge_branches(then_value, else_value, relaxations)
      if then_value.is_a?(Interval) && else_value.is_a?(Interval)
        then_value.hull(else_value)
      elsif !then_value.is_a?(Interval) && !else_value.is_a?(Interval)
        then_value == else_value ? then_value : INDETERMINATE
      else
        relaxations << Relaxation.new(
          :unsupported_operation,
          "branches mix numeric and logical values; widening to unbounded"
        )
        Interval.unbounded
      end
    end

    def walk_function(node, context, relaxations, undefined)
      name = node.class.name.to_s.downcase
      rule = rules[name]
      args = node.args.map { |arg| walk(arg, context, relaxations, undefined) }

      if rule
        rule.call(*args)
      else
        relaxations << Relaxation.new(
          :unknown_rule,
          "no interval rule for function '" + name + "'; widening to unbounded"
        )
        Interval.unbounded
      end
    end
  end
end

