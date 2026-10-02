require_relative 'exceptions'
require_relative 'numeric_parser'
require_relative 'decimal_functions'
require 'bigdecimal'
require 'bigdecimal/util'

module Dentaku
  class DecimalContext
    ROUNDING_MODES = {
      up: ::BigDecimal::ROUND_UP,
      down: ::BigDecimal::ROUND_DOWN,
      ceiling: ::BigDecimal::ROUND_CEILING,
      ceil: ::BigDecimal::ROUND_CEILING,
      floor: ::BigDecimal::ROUND_FLOOR,
      half_up: ::BigDecimal::ROUND_HALF_UP,
      half_down: ::BigDecimal::ROUND_HALF_DOWN,
      half_even: ::BigDecimal::ROUND_HALF_EVEN,
      banker: ::BigDecimal::ROUND_HALF_EVEN
    }.freeze

    SIGNALS = %i[division_by_zero overflow inexact].freeze
    MAX_EXPONENT = 999_999

    attr_reader :precision, :rounding_mode

    def initialize(precision: 16, rounding_mode: :half_up, traps: nil, **signal_options)
      @precision = validate_precision(precision)
      @rounding_mode = validate_rounding_mode(rounding_mode)
      @traps = parse_traps(traps, signal_options)
      @signals = []
    end

    def signals
      @signals.dup.freeze
    end

    def begin_calculation
      @signals = []
    end

    def reset!
      @signals = []
      self
    end

    def signal(name)
      raise ::ArgumentError, "unknown decimal signal #{name.inspect}" unless SIGNALS.include?(name)

      @signals << name unless @signals.include?(name)
      raise DecimalError.for(name) if trap?(name)
    end

    def trap?(name)
      @traps.fetch(name)
    end

    def cast(value)
      Dentaku::DecimalArithmetic.cast(value, self)
    end

    def add(left, right)
      Dentaku::DecimalArithmetic.add(left, right, self)
    end

    def subtract(left, right)
      Dentaku::DecimalArithmetic.subtract(left, right, self)
    end

    def multiply(left, right)
      Dentaku::DecimalArithmetic.multiply(left, right, self)
    end

    def divide(left, right)
      Dentaku::DecimalArithmetic.divide(left, right, self)
    end

    def modulo(left, right)
      Dentaku::DecimalArithmetic.modulo(left, right, self)
    end

    def power(base, exponent)
      Dentaku::DecimalArithmetic.power(base, exponent, self)
    end

    private

    def validate_precision(value)
      precision = Integer(value)
      return precision if precision.positive?

      raise ::ArgumentError, "decimal precision must be positive"
    rescue ::TypeError, ::ArgumentError => e
      raise ::ArgumentError, "invalid decimal precision #{value.inspect}: #{e.message}"
    end

    def validate_rounding_mode(value)
      case value
      when Symbol
        ROUNDING_MODES.fetch(value) do
          raise ::ArgumentError, "unknown decimal rounding mode #{value.inspect}"
        end
      when Integer
        raise ::ArgumentError, "unknown decimal rounding mode #{value.inspect}" unless ROUNDING_MODES.value?(value)

        value
      else
        raise ::ArgumentError, "invalid decimal rounding mode #{value.inspect}"
      end
    end

    def parse_traps(traps, options)
      configured = traps || {}
      raise ::ArgumentError, "decimal traps must be a Hash" unless configured.is_a?(::Hash)

      signals = options.slice(*SIGNALS).transform_values { |value| normalize_trap(value) }
      traps_hash = configured.transform_keys(&:to_sym).transform_values { |value| normalize_trap(value) }
      unknown = traps_hash.keys - SIGNALS
      raise ::ArgumentError, "unknown decimal signal #{unknown.first.inspect}" if unknown.any?

      SIGNALS.to_h { |name| [name, traps_hash.fetch(name, signals.fetch(name, true))] }
    end

    def normalize_trap(value)
      case value
      when :raise, true then true
      when :record, false then false
      else
        raise ::ArgumentError, "decimal signal action must be :raise or :record"
      end
    end
  end

  module DecimalArithmetic
    class << self
      def cast(value, context)
        case value
        when ::BigDecimal
          return value if value.nan? || value.infinite?

          value
        when ::Integer
          value.to_d
        when ::Rational
          finish_rational(value, context, false)
        when ::String
          NumericParser.decimal_value(value) ||
            raise(Dentaku::ArgumentError.for(:invalid_value, actual: value, expected: BigDecimal),
                  "String input '#{value}' is not coercible to numeric")
        else
          raise Dentaku::ArgumentError.for(:incompatible_type, actual: value, expected: BigDecimal),
                "#{value.class} is not supported in decimal calculations"
        end
      end

      def add(left, right, context)
        finish_rational(to_rational(left) + to_rational(right), context)
      end

      def subtract(left, right, context)
        finish_rational(to_rational(left) - to_rational(right), context)
      end

      def multiply(left, right, context)
        finish_rational(to_rational(left) * to_rational(right), context)
      end

      def divide(left, right, context)
        dividend = cast(left, context)
        divisor = cast(right, context)
        return zero_division(dividend, context) if divisor.zero?

        finish_rational(to_rational(dividend) / to_rational(divisor), context)
      end

      def modulo(left, right, context)
        dividend = cast(left, context)
        divisor = cast(right, context)
        return zero_division(dividend, context) if divisor.zero?

        finish_rational(to_rational(dividend) % to_rational(divisor), context)
      end

      def power(base, exponent, context)
        decimal_base = cast(base, context)
        decimal_exponent = cast(exponent, context)
        rational_base = to_rational(decimal_base)
        rational_exponent = to_rational(decimal_exponent)

        if decimal_base.zero?
          return 1.to_d if rational_exponent.zero?
          return 0.to_d if rational_exponent.positive?

          return zero_division(1.to_d, context)
        end

        if decimal_exponent.frac.zero?
          integer_power(decimal_base, rational_exponent.to_i, context)
        elsif rational_base.negative?
          raise Dentaku::MathDomainError.new('power', [decimal_base, decimal_exponent])
        else
          exact_root = exact_rational_power(rational_base, rational_exponent)
          if exact_root
            finish_rational(exact_root, context)
          else
            approximate_power(decimal_base, decimal_exponent, context)
          end
        end
      end

      private

      def integer_power(base, exponent, context)
        estimate = power_exponent_estimate(base, exponent)
        if exponent.positive? && estimate >= DecimalContext::MAX_EXPONENT
          return exponent.positive? ? power_overflow(context) : 0.to_d
        elsif exponent.negative? && estimate < -DecimalContext::MAX_EXPONENT
          return 0.to_d
        end

        result = base.power(exponent, context.precision + 5)
        finish_decimal(result, context, true)
      end

      def power_overflow(context)
        context.signal(:overflow)
        ::BigDecimal::INFINITY
      end

      def approximate_power(base, exponent, context)
        result = base.power(exponent, context.precision + 10)
        finish_decimal(result, context, false)
      end

      def power_exponent_estimate(base, exponent)
        if exponent.zero? || base == 1
          0
        elsif exponent.positive?
          decimal_exponent(base.abs) * exponent
        else
          -decimal_exponent(base.abs) * exponent.abs
        end
      end

      def decimal_exponent(value)
        rational = value.to_r
        exponent = value.exponent - 1
        exponent += 1 while 10**(exponent + 1) <= rational
        exponent -= 1 while 10**exponent > rational
        exponent
      end

      def exact_rational_power(base, exponent)
        numerator_root = integer_root(base.numerator.abs, exponent.denominator)
        denominator_root = integer_root(base.denominator, exponent.denominator)
        return nil unless numerator_root && denominator_root

        root = numerator_root.to_r / denominator_root
        return root if exponent.numerator.zero?

        powered = root**exponent.numerator.abs
        exponent.negative? ? 1 / powered : powered
      end

      def integer_root(value, degree)
        return value if degree == 1 || value <= 1
        return nil if degree > 1000

        low = 0
        high = [1, root_upper_bound(value, degree)].max

        while low <= high
          middle = (low + high) / 2
          powered = middle**degree

          if powered == value
            return middle
          elsif powered < value
            low = middle + 1
          else
            high = middle - 1
          end
        end

        nil
      end

      def root_upper_bound(value, degree)
        bit_length = value.bit_length
        quotient, remainder = (bit_length - 1).divmod(degree)
        shift = quotient + (remainder.zero? ? 0 : 1)
        2.pow(shift)
      end

      def zero_division(dividend, context)
        result = if dividend.zero?
          ::BigDecimal::NAN
        elsif dividend.negative?
          ::BigDecimal::INFINITY * (-1)
        else
          ::BigDecimal::INFINITY
        end

        context.signal(:division_by_zero)
        result
      end

      def finish_rational(value, context, should_record_inexact = true)
        if finite_decimal(value)
          finish_decimal(value.to_d, context, true)
        else
          precision_guard = context.precision + 10
          dividend = BigDecimal(value.numerator)
          divisor = BigDecimal(value.denominator)
          approximate = dividend.div(divisor, precision_guard)
          finish_decimal(approximate, context, should_record_inexact)
        end
      end

      def finish_decimal(value, context, exact)
        rounded = value.infinite? || value.nan? ? value : round_to_significant_digits(value, context)
        return rounded if rounded.infinite? && (value.infinite? || value.nan?)

        if rounded.infinite?
          context.signal(:overflow)
        elsif rounded.finite? && rounded.exponent.abs > DecimalContext::MAX_EXPONENT
          context.signal(:overflow)
        end
        result_inexact = !rounded.infinite? && !rounded.nan? && (!exact || rounded != value)
        context.signal(:inexact) if result_inexact
        rounded
      end

      def round_to_significant_digits(value, context)
        return BigDecimal(0) if value.zero?
        value = value.to_d if value.is_a?(::Rational)

        sign, digits, _base, exponent = value.split
        digits = digits.to_s
        rounded_digits = round_decimal_digits(digits, context.precision, sign, context.rounding_mode)
        return BigDecimal(0) if rounded_digits.nil?

        BigDecimal(sign) * BigDecimal(rounded_digits) * BigDecimal(10).power(exponent - rounded_digits.length, 20)
      end
      def round_decimal_digits(digits, precision, sign, mode)
        return digits[0, precision] if digits.length <= precision

        kept = digits[0, precision].to_i
        next_digit = digits[precision].to_i
        remainder = digits[(precision + 1)..].to_i
        increase = round_digit?(next_digit, remainder, sign, mode, kept)
        kept += 1 if increase
        kept.to_s
      end

      def round_digit?(next_digit, remainder, sign, mode, kept)
        non_exact = next_digit.nonzero? || remainder.nonzero?
        case mode
        when ::BigDecimal::ROUND_UP then non_exact
        when ::BigDecimal::ROUND_DOWN then false
        when ::BigDecimal::ROUND_CEILING then sign.positive? && non_exact
        when ::BigDecimal::ROUND_FLOOR then sign.negative? && non_exact
        when ::BigDecimal::ROUND_HALF_UP then next_digit > 5 || (next_digit == 5)
        when ::BigDecimal::ROUND_HALF_DOWN
          next_digit > 5 || (next_digit == 5 && remainder.nonzero?)
        when ::BigDecimal::ROUND_HALF_EVEN
          next_digit > 5 || (next_digit == 5 && (remainder.nonzero? || kept.odd?))
        end
      end

      def finite_decimal(rational)
        denominator = rational.denominator
        denominator /= 2 while denominator.even?
        denominator /= 5 while denominator % 5 == 0
        denominator == 1
      end

      def to_rational(value)
        case value
        when ::Rational then value
        when ::BigDecimal then value.to_r
        else value.to_r
        end
      end
    end
  end
end
