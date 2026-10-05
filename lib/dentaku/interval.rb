module Dentaku
  # A closed numeric interval [lo, hi] with outward-rounded arithmetic, used
  # by Dentaku's interval evaluation mode (see IntervalEvaluator). Every
  # operation rounds its lower bound toward -Infinity and its upper bound
  # toward +Infinity by one ulp (Float#prev_float / Float#next_float), so the
  # resulting interval always contains the exact mathematical result set --
  # the rounding direction is explicit and never narrows an interval.
  #
  # Bounds are Floats and may be infinite. The canonical empty interval is
  # [Infinity, -Infinity] and represents "no defined values" (e.g. the
  # quotient when the divisor is exactly zero).
  class Interval
    INFINITY = Float::INFINITY

    attr_reader :lo, :hi

    def initialize(lo, hi)
      lo = Float(lo)
      hi = Float(hi)

      if lo > hi && !(lo == INFINITY && hi == -INFINITY)
        raise ::ArgumentError, "interval lower bound #{lo} exceeds upper bound #{hi}"
      end

      @lo = lo
      @hi = hi
    end

    # the interval containing exactly +value+
    def self.point(value)
      new(value, value)
    end

    # the interval containing every real number
    def self.unbounded
      new(-INFINITY, INFINITY)
    end

    # the interval containing no values at all
    def self.empty
      new(INFINITY, -INFINITY)
    end

    # Coerces +value+ to an Interval. Accepts Interval (returned as-is),
    # Numeric (a point), Range (beginless/endless bounds become infinite;
    # exclude_end is ignored, which is conservative), and a two-element
    # Array [lo, hi].
    def self.from(value)
      case value
      when Interval
        value
      when ::Numeric
        point(value)
      when ::Range
        new(value.begin || -INFINITY, value.end || INFINITY)
      when ::Array
        unless value.length == 2
          raise ::ArgumentError, "cannot coerce #{value.inspect} to an interval"
        end

        new(value[0], value[1])
      else
        raise ::ArgumentError, "cannot coerce #{value.inspect} to an interval"
      end
    end

    # Rounds +value+ one ulp toward -Infinity. Infinities pass through.
    def self.widen_lo(value)
      value.finite? ? value.prev_float : value
    end

    # Rounds +value+ one ulp toward +Infinity. Infinities pass through.
    def self.widen_hi(value)
      value.finite? ? value.next_float : value
    end

    def empty?
      lo > hi
    end

    def point?
      lo == hi
    end

    def unbounded?
      lo == -INFINITY || hi == INFINITY
    end

    def includes_zero?
      !empty? && lo <= 0.0 && 0.0 <= hi
    end

    def spans_zero?
      !empty? && lo < 0.0 && 0.0 < hi
    end

    def contains?(value)
      !empty? && lo <= value && value <= hi
    end

    def ==(other)
      other.is_a?(Interval) && lo == other.lo && hi == other.hi
    end
    alias_method :eql?, :==

    def hash
      [lo, hi].hash
    end

    def +(other)
      other = Interval.from(other)
      return Interval.empty if empty? || other.empty?

      Interval.new(
        Interval.widen_lo(lo + other.lo),
        Interval.widen_hi(hi + other.hi)
      )
    end

    def -(other)
      self + (-Interval.from(other))
    end

    def -@
      return Interval.empty if empty?

      Interval.new(-hi, -lo)
    end

    def *(other)
      other = Interval.from(other)
      return Interval.empty if empty? || other.empty?

      products = [lo * other.lo, lo * other.hi, hi * other.lo, hi * other.hi]

      # 0 * Infinity is NaN; a zero factor times an unbounded factor can
      # approach any real number, so the only safe hull is everything
      return Interval.unbounded if products.any?(&:nan?)

      Interval.new(
        Interval.widen_lo(products.min),
        Interval.widen_hi(products.max)
      )
    end

    def /(other)
      self * Interval.from(other).reciprocal
    end

    # The interval 1 / self. A divisor spanning zero in its interior yields
    # an unbounded result; a divisor that only touches zero yields a
    # one-sided unbounded result; a divisor that is exactly zero yields the
    # empty interval (no defined values).
    def reciprocal
      return Interval.empty if empty? || (lo == 0.0 && hi == 0.0)
      return Interval.unbounded if spans_zero?

      lower = lo == 0.0 ? INFINITY : 1.0 / lo
      upper = hi == 0.0 ? -INFINITY : 1.0 / hi

      Interval.new(
        Interval.widen_lo([lower, upper].min),
        Interval.widen_hi([lower, upper].max)
      )
    end

    # Interval power for integer exponents. Negative exponents are the
    # reciprocal of the corresponding positive power, so a base containing
    # zero produces an unbounded or empty result exactly as division does.
    def **(exponent)
      n = Integer(exponent)
      return Interval.empty if empty?
      return Interval.point(1.0) if n.zero?
      return reciprocal**(-n) if n.negative?

      if n.odd?
        Interval.new(Interval.widen_lo(lo**n), Interval.widen_hi(hi**n))
      elsif includes_zero?
        Interval.new(0.0, Interval.widen_hi([lo.abs, hi.abs].max**n))
      elsif lo >= 0.0
        Interval.new(Interval.widen_lo(lo**n), Interval.widen_hi(hi**n))
      else
        Interval.new(Interval.widen_lo(hi**n), Interval.widen_hi(lo**n))
      end
    end

    def abs
      return Interval.empty if empty?
      return Interval.new(0.0, [lo.abs, hi.abs].max) if includes_zero?

      Interval.new([lo.abs, hi.abs].min, [lo.abs, hi.abs].max)
    end

    def min(other)
      other = Interval.from(other)
      return Interval.empty if empty? || other.empty?

      Interval.new([lo, other.lo].min, [hi, other.hi].min)
    end

    def max(other)
      other = Interval.from(other)
      return Interval.empty if empty? || other.empty?

      Interval.new([lo, other.lo].max, [hi, other.hi].max)
    end

    # The smallest interval containing both self and other.
    def hull(other)
      other = Interval.from(other)
      return other if empty?
      return self if other.empty?

      Interval.new([lo, other.lo].min, [hi, other.hi].max)
    end

    # Tri-state comparisons, returning :true, :false, or :indeterminate when
    # the intervals overlap in a way that admits both outcomes.
    def lt(other)
      other = Interval.from(other)
      return :indeterminate if empty? || other.empty?
      return :true if hi < other.lo
      return :false if lo >= other.hi

      :indeterminate
    end

    def le(other)
      other = Interval.from(other)
      return :indeterminate if empty? || other.empty?
      return :true if hi <= other.lo
      return :false if lo > other.hi

      :indeterminate
    end

    def gt(other)
      Interval.from(other).lt(self)
    end

    def ge(other)
      Interval.from(other).le(self)
    end

    def eq(other)
      other = Interval.from(other)
      return :indeterminate if empty? || other.empty?
      return :true if point? && other.point? && lo == other.lo
      return :false if hi < other.lo || lo > other.hi

      :indeterminate
    end

    def ne(other)
      case eq(other)
      when :true then :false
      when :false then :true
      else :indeterminate
      end
    end

    def to_s
      return "(empty)" if empty?

      "[#{lo}, #{hi}]"
    end

    def inspect
      "#<Dentaku::Interval #{self}>"
    end
  end
end
