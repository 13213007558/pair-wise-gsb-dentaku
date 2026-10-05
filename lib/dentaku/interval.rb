require 'bigdecimal'
require 'bigdecimal/util'

module Dentaku
  # A closed numeric interval [low, high] over the extended reals.
  #
  # Finite endpoints are kept internally as Rational so every arithmetic rule
  # stays exact; outward rounding to BigDecimal only happens when results are
  # returned to callers. Float::INFINITY represents an unbounded endpoint.
  class Interval
    include Comparable

    NEGATIVE_INFINITY = -Float::INFINITY
    POSITIVE_INFINITY = Float::INFINITY

    class << self
      alias_method :[], :new

      def point(value)
        new(value, value)
      end

      def numeric(value)
        return value if value.is_a?(Interval)

        point(value)
      end

      # smallest closed interval containing every argument. `nil` bounds mean
      # "unbounded on this side" and are accepted for caller convenience.
      def hull(*intervals)
        intervals = intervals.flatten.compact
        raise ::ArgumentError, "cannot build a hull without intervals" if intervals.empty?

        lows = intervals.map(&:low)
        highs = intervals.map(&:high)
        new(lows.min, highs.max)
      end
    end

    attr_reader :low, :high

    def initialize(low, high)
      @low = normalize(low)
      @high = normalize(high)
      raise ::ArgumentError, "invalid interval [#{low}, #{high}]" if @low > @high
    end

    def <=>(other)
      return unless other.is_a?(Interval)

      [low, high] <=> [other.low, other.high]
    end

    def ==(other)
      other.is_a?(Interval) && low == other.low && high == other.high
    end
    alias_method :eql?, :==

    def hash
      [Interval, low, high].hash
    end

    def degenerate?
      low == high
    end
    alias_method :point?, :degenerate?

    def unbounded?
      !finite?
    end

    def finite?
      finite_value?(low) && finite_value?(high)
    end

    def contains_zero?
      low <= 0 && high >= 0
    end

    def zero?
      low == 0 && high == 0
    end

    def include?(value)
      return false unless finite_value?(value)

      value = normalize(value)
      low <= value && value <= high
    end
    alias_method :cover?, :include?

    def neg
      Interval.new(-high, -low)
    end

    def add(other)
      other = coerce_other(other)
      Interval.new(add_endpoint(low, other.low), add_endpoint(high, other.high))
    end

    def sub(other)
      other = coerce_other(other)
      Interval.new(add_endpoint(low, -other.high), add_endpoint(high, -other.low))
    end

    def mul(other)
      other = coerce_other(other)
      return Interval::ZERO if zero? || other.zero?

      products = [
        mul_endpoint(low, other.low),
        mul_endpoint(low, other.high),
        mul_endpoint(high, other.low),
        mul_endpoint(high, other.high)
      ].compact

      Interval.new(products.min, products.max)
    end

    # Division. Returns [interval, undefined_inputs]. When the divisor
    # straddles zero the image of every *defined* input is unbounded, while
    # the exact divisor value(s) at zero stay undefined and are returned
    # separately so callers can distinguish "unbounded" from "undefined".
    def div(other)
      other = coerce_other(other)
      raise Dentaku::ZeroDivisionError if other.zero?

      reciprocal, undefined = other.inv
      [mul(reciprocal), undefined]
    end

    # Reciprocal image 1/x together with the points at which 1/x is not
    # defined. Returns [image_interval, undefined_inputs].
    def inv
      image = if low < 0 && high > 0
                Interval::UNIVERSE
              elsif high.zero? && low < 0
                Interval.new(NEGATIVE_INFINITY, 1 / low)
              elsif low.zero? && high > 0
                Interval.new(1 / high, POSITIVE_INFINITY)
              else
                Interval.new(1 / high, 1 / low)
              end

      [image, contains_zero? && !zero? ? [0] : []]
    end

    # Integer power. Returns [interval, undefined_inputs] because negative
    # exponents are undefined when the base contains zero.
    def ipow(exponent)
      exponent = Integer(exponent)
      return [Interval.point(1), []] if exponent.zero?

      if exponent.positive?
        [positive_power(exponent), []]
      else
        powered = positive_power(-exponent)
        powered.inv
      end
    end

    def abs
      return self if low >= 0
      return neg if high <= 0

      Interval.new(0, [-low, high].max)
    end

    def sample_grid(steps)
      return [low] if degenerate?
      raise ::ArgumentError, "cannot sample an unbounded interval" unless finite?

      steps = steps.to_i
      raise ::ArgumentError, "steps must be positive" unless steps.positive?

      (0..steps).map { |index| low + ((high - low) * index) / steps }
    end

    # Outward rounding: the low endpoint rounds toward -Infinity and the high
    # endpoint toward +Infinity, so the rounded interval still contains the
    # exact one. Integral endpoints stay integers. Returns the rounded interval
    # plus a flag saying whether either bound actually moved.
    def round_outward(precision = 16)
      return [self, false] if precision.nil?

      rounded_low, low_moved = round_bound(low, precision, :down)
      rounded_high, high_moved = round_bound(high, precision, :up)
      [Interval.new(rounded_low, rounded_high), low_moved || high_moved]
    end

    def to_s
      "[#{format_endpoint(low)}, #{format_endpoint(high)}]"
    end
    alias_method :inspect, :to_s

    def to_a
      [low, high]
    end

    private

    def positive_power(exponent)
      return self if exponent == 1
      return Interval.new(low**exponent, high**exponent) if low >= 0
      return neg_powered_even(exponent) if high <= 0

      if exponent.even?
        Interval.new(0, [low**exponent, high**exponent].max)
      else
        Interval.new(low**exponent, high**exponent)
      end
    end

    def neg_powered_even(exponent)
      if exponent.even?
        Interval.new((-high)**exponent, (-low)**exponent)
      else
        Interval.new((-low)**exponent * -1, (-high)**exponent * -1)
      end
    end

    def coerce_other(other)
      other.is_a?(Interval) ? other : Interval.point(other)
    end

    def normalize(value)
      return value if value == NEGATIVE_INFINITY || value == POSITIVE_INFINITY

      value.is_a?(Rational) ? value : Rational(value)
    end

    def finite_value?(value)
      value.is_a?(Numeric) && value.respond_to?(:finite?) ? value.finite? : true
    end

    def add_endpoint(left, right)
      return if [left, right].include?(nil)
      return left + right unless infinite?(left) || infinite?(right)

      # adding a finite value leaves the infinite endpoint in place; adding
      # infinities keeps the sign unless the opposing infinities meet, in
      # which case no single endpoint exists and that side is dropped via nil
      if infinite?(left) && infinite?(right)
        left == right ? left : nil
      elsif infinite?(left)
        left
      else
        right
      end
    end

    def mul_endpoint(left, right)
      return 0 if (infinite?(left) && right.zero?) || (left.zero? && infinite?(right))

      left * right
    end

    def round_bound(value, precision, direction)
      return [value, false] if infinite?(value)
      return [value.to_i, false] if value.denominator == 1

      order = decimal_order(value.abs)
      scale = 10**(precision - 1 - order)
      scaled = value * scale
      floor = scaled.numerator.div(scaled.denominator)
      remainder = scaled.numerator.modulo(scaled.denominator)
      quantized = if direction == :down
                    floor
                  else
                    remainder.zero? ? floor : floor + 1
                  end
      candidate = Rational(quantized, scale)
      # exact finite-decimal value (e.g. 57/5 at enough precision): keep it
      # exactly instead of forcing a rounding artifact
      return [candidate, false] if candidate == value

      [decimal_from_rational(candidate), true]
    end

    # decimal exponent of the most significant digit, computed with integer
    # arithmetic so no floating-point error leaks into the rounding decision
    def decimal_order(positive_rational)
      numerator = positive_rational.numerator
      denominator = positive_rational.denominator
      integer_part = numerator.div(denominator)

      if integer_part >= 1
        order = 0
        ten_pow = 1
        while ten_pow * 10 <= integer_part
          ten_pow *= 10
          order += 1
        end
        order
      else
        order = -1
        scaled = numerator * 10
        while scaled < denominator
          scaled *= 10
          order -= 1
        end
        order
      end
    end

    # exact decimal expansion of a rational whose denominator is a power of ten
    def decimal_from_rational(rational)
      sign = rational.negative? ? '-' : ''
      magnitude = rational.abs
      # candidates from round_bound always have a 10^n denominator
      denominator_digits = magnitude.denominator.to_s.length - 1
      digits = magnitude.numerator.to_s.rjust(denominator_digits + 1, '0')
      text = if denominator_digits.zero?
               "#{sign}#{digits}"
             elsif digits.length <= denominator_digits
               "#{sign}0.#{digits.rjust(denominator_digits, '0')}"
             else
               "#{sign}#{digits[0...-denominator_digits]}.#{digits[-denominator_digits..]}"
             end
      BigDecimal(text)
    end

    def infinite?(value)
      value == POSITIVE_INFINITY || value == NEGATIVE_INFINITY
    end

    def format_endpoint(value)
      infinite?(value) ? (value.positive? ? 'Infinity' : '-Infinity') : value.to_s
    end

    UNIVERSE = new(NEGATIVE_INFINITY, POSITIVE_INFINITY).freeze
    ZERO = new(0, 0).freeze
  end
end
