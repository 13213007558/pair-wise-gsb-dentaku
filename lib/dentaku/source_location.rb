module Dentaku
  # A span of the original expression text. Static analysis (the type
  # checker) attaches these to AST nodes so findings can be pointed back
  # at the user's input.
  class SourceLocation
    include Comparable

    attr_reader :offset, :length

    def initialize(offset, length)
      @offset = offset
      @length = length
    end

    def end_offset
      offset + length
    end

    def to_range
      offset...end_offset
    end

    # the slice of +source+ this location points at
    def snippet(source)
      source[offset, length]
    end

    def <=>(other)
      [offset, length] <=> [other.offset, other.length]
    end

    def ==(other)
      other.is_a?(SourceLocation) &&
        offset == other.offset &&
        length == other.length
    end
    alias_method :eql?, :==

    def hash
      [offset, length].hash
    end

    def to_s
      "#{offset}...#{end_offset}"
    end
    alias_method :inspect, :to_s
  end
end
