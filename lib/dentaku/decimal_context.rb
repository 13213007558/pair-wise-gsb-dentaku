require 'bigdecimal'

module Dentaku
  class DecimalContext
    SIGNALS = %i[division_by_zero overflow inexact].freeze
    ROUNDING_MODES = {
      up: BigDecimal::ROUND_UP,
      down: BigDecimal::ROUND_DOWN,
      ceiling: BigDecimal::ROUND_CEILING,
      floor: BigDecimal::ROUND_FLOOR,
      half_up: BigDecimal::ROUND_HALF_UP,
      half_down: BigDecimal::ROUND_HALF_DOWN,
      half_even: BigDecimal::ROUND_HALF_EVEN
    }.freeze

    attr_reader :precision, :rounding, :traps

    def initialize(precision: 28, rounding: :half_up, traps: nil)
      unless precision.is_a?(::Integer) && precision.positive?
        raise ::ArgumentError, 'decimal precision must be a positive Integer'
      end

      rounding = rounding.to_sym if rounding.is_a?(::String)
      unless ROUNDING_MODES.key?(rounding)
        raise ::ArgumentError, "unsupported decimal rounding mode #{rounding.inspect}"
      end

      traps = traps || {}
      unless traps.is_a?(::Hash) && (traps.keys - SIGNALS).empty? &&
             traps.values.all? { |value| value == true || value == false }
        raise ::ArgumentError, 'decimal traps must map signals to true or false'
      end

      @precision = precision
      @rounding = rounding
      @traps = { division_by_zero: true, overflow: true, inexact: true }.merge(traps).freeze
    end

    def rounding_mode
      ROUNDING_MODES.fetch(rounding)
    end

    def trap?(signal)
      traps.fetch(signal)
    end

    def begin_execution
      Execution.new(self)
    end

    class Result < SimpleDelegator
      attr_reader :value, :signals

      def initialize(value, signals)
        @value = value
        @signals = signals
        super(value)
      end

      class << self
        def wrap(value, signals)
          new(value, signals)
        end
      end
    end

    class Execution
      MAX_EXPONENT = 999_999

      attr_reader :context

      def initialize(context)
        @context = context
        @signals = []
      end

      def precision
        context.precision
      end

      def rounding_mode
        context.rounding_mode
      end

      def signals
        SIGNALS.select { |signal| @signals.include?(signal) }
      end

      def decimal(value)
        case value
        when BigDecimal
          value
        when Integer
          BigDecimal(value)
        when DecimalContext::Result
          decimal(value.value)
        when String
          parse_string(value)
        else
          raise Dentaku::ArgumentError.for(:incompatible_type, actual: value, expected: BigDecimal),
                "#{value.class} is not supported in decimal context"
        end
      end

      def fit(value, report_inexact: true)
        return value unless finite?(value)

        rounded = value.round(precision - value.exponent, rounding_mode)
        signal(:inexact) if report_inexact && rounded != value
        overflow(rounded) if rounded.exponent > MAX_EXPONENT
        rounded
      rescue ::FloatDomainError => error
        raise unless error.instance_of?(::FloatDomainError)
        value
      end

      def add(left, right)
        left = coerce(left)
        right = coerce(right)
        operation_result(left + right)
      end

      def subtract(left, right)
        left = coerce(left)
        right = coerce(right)
        operation_result(left - right)
      end

      def multiply(left, right)
        left = coerce(left)
        right = coerce(right)
        operation_result(left * right)
      end

      def divide(left, right)
        dividend = coerce(left)
        divisor = coerce(right)
        return divide_by_zero(dividend, divisor) if divisor.zero?

        exact = terminating?(dividend, divisor)
        quotient = dividend.div(divisor, exact ? 0 : precision + 1)
        result = fit(quotient, report_inexact: false)
        signal(:inexact) unless exact && result == quotient
        result
      end

      def modulo(left, right)
        dividend = coerce(left)
        divisor = coerce(right)
        return divide_by_zero(dividend, divisor) if divisor.zero?

        _quotient, remainder = dividend.divmod(divisor)
        fit(remainder, report_inexact: false)
      end

      def power(left, right)
        base = coerce(left)
        exponent = coerce(right)

        if exponent.infinite? || exponent.nan? || base.nan?
          raise Dentaku::ArgumentError.for(:invalid_value, actual: right), 'invalid decimal exponent'
        end

        if exponent == 0
          return fit(BigDecimal(1))
        end
        return divide_by_zero(base, exponent) if base.zero? && exponent.negative?

        if exponent == exponent.to_i
          integer_power(base, exponent.to_i)
        else
          fractional_power(base, exponent)
        end
      end

      def negate(value)
        fit(-coerce(value), report_inexact: false)
      end

      def percent(value)
        divide(coerce(value), BigDecimal(100))
      end

      def abs(value)
        fit(coerce(value).abs, report_inexact: false)
      end

      def round(value, places)
        number = coerce(value)
        places = integer(places)
        rounded = number.round(places, rounding_mode)
        signal(:inexact) if rounded != number
        fit(rounded, report_inexact: false)
      end

      def roundup(value, places)
        directional_round(value, places, 1)
      end

      def rounddown(value, places)
        directional_round(value, places, -1)
      end

      def sum(values)
        raise_empty_values('SUM') if values.empty?
        values.reduce(BigDecimal(0)) { |total, value| fit(total + coerce(value)) }
      end

      def product(values)
        raise_empty_values('MUL') if values.empty?
        values.reduce(BigDecimal(1)) { |total, value| fit(total * coerce(value)) }
      end

      def average(values)
        raise_empty_values('AVG') if values.empty?
        divide(sum(values), values.length)
      end

      def min(values)
        values.map { |value| coerce(value) }.min
      end

      def max(values)
        values.map { |value| coerce(value) }.max
      end

      private

      def integer(value)
        number = coerce(value)
        integer_value = number.to_i
        unless number == integer_value
          raise Dentaku::ArgumentError.for(:invalid_value, actual: value),
                'decimal rounding places must be an integer'
        end

        integer_value
      end

      def raise_empty_values(function_name)
        raise Dentaku::ArgumentError.for(
          :too_few_arguments,
          function_name: function_name, expected: 1.., actual: 0
        )
      end

      def directional_round(value, places, direction)
        number = coerce(value)
        places = integer(places)
        scaled = shift(number, places)
        rounded = direction.positive? ? scaled.ceil : scaled.floor
        rounded = BigDecimal(rounded)
        signal(:inexact) if rounded != scaled
        fit(shift(rounded, -places), report_inexact: false)
      end

      def shift(value, places)
        factor = BigDecimal(10).power(places.abs)
        places.negative? ? value.div(factor, 0) : value * factor
      end

      def integer_power(base, exponent)
        magnitude = exponent.abs
        return extreme_power(base, exponent) if magnitude > MAX_EXPONENT

        result = base.power(magnitude)
        result = divide(BigDecimal(1), result) if exponent.negative?
        return operation_result(result) unless exponent.negative?
        result
      end

      def fractional_power(base, exponent)
        unless base.positive?
          raise Dentaku::ArgumentError.for(:invalid_value, actual: base),
                'non-integer decimal powers require a positive base'
        end

        return extreme_power(base, exponent) if exponent.abs > MAX_EXPONENT

        approximate = base.power(exponent, precision + 1)
        result = fit(approximate, report_inexact: false)
        rational = base.to_r ** exponent.to_r
        signal(:inexact) unless result.to_r == rational
        result
      end

      def terminating?(dividend, divisor)
        rational = dividend.to_r / divisor.to_r
        denominator = rational.denominator
        denominator /= 2 while denominator.even?
        denominator /= 5 while denominator % 5 == 0
        denominator == 1
      end

      def parse_string(value)
        exact_parse_string(value) ||
          raise(Dentaku::ArgumentError.for(:incompatible_type, actual: value, expected: BigDecimal),
                "#{value.inspect} is not a decimal number")
      end

      def exact_parse_string(value)
        return nil unless NumericParser.match(value)

        negative = value.start_with?('-')
        number = negative ? value[1..] : value
        if number =~ /\A0x/i
          NumericParser.parse_hexadecimal_string(number).then { |parsed| negative ? -parsed : parsed }
        else
          NumericParser.parse_exact_numeric_string(number).then { |parsed| negative ? -parsed : parsed }
        end
      end

      def finite?(value)
        value.respond_to?(:finite?) && value.finite?
      end

      def coerce(value)
        fit(decimal(value))
      end

      def operation_result(value)
        rounded = fit(value, report_inexact: false)
        signal(:inexact) if rounded != value
        rounded
      end

      def extreme_power(base, exponent)
        return fit(BigDecimal(1)) if base.abs == 1

        grows_with_positive_power = base.abs > 1
        overflowing = exponent.positive? ? grows_with_positive_power : !grows_with_positive_power
        return overflow(base) if overflowing
        fit(BigDecimal(0))
      end

      def signal_once(signal)
        @signals << signal unless @signals.include?(signal)
      end

      def signal(signal)
        signal_once(signal)
        return unless context.trap?(signal)

        error_class = case signal
                      when :division_by_zero then Dentaku::ZeroDivisionError
                      when :overflow then Dentaku::DecimalOverflowError
                      when :inexact then Dentaku::DecimalInexactError
                      end
        raise error_class.new(signals)
      end

      def divide_by_zero(dividend, divisor)
        negative = (dividend.sign * divisor.sign).negative?
        infinity = BigDecimal(negative ? '-Infinity' : 'Infinity')
        signal(:division_by_zero)
        infinity
      end

      def overflow(value)
        infinity = BigDecimal(value.negative? ? '-Infinity' : 'Infinity')
        signal(:overflow)
        infinity
      end
    end
  end

  class DecimalOverflowError < ::FloatDomainError
    include Error

    attr_reader :signals

    def initialize(signals)
      @signals = signals
      super('decimal overflow')
    end
  end

  class DecimalInexactError < ::FloatDomainError
    include Error

    attr_reader :signals

    def initialize(signals)
      @signals = signals
      super('decimal result is inexact')
    end
  end

  class DecimalUnsupportedError < BaseError
    def initialize(function_name)
      super("#{function_name}() does not support exact decimal semantics")
    end
  end
end
