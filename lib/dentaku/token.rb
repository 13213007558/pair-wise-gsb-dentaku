module Dentaku
  class Token
    attr_reader :category, :raw_value, :value, :start_position, :end_position

    def initialize(category, value, raw_value = nil, start_position: nil, end_position: nil)
      @category  = category
      @value     = value
      @raw_value = raw_value
      @start_position = start_position
      @end_position = end_position
    end

    # zero-based [start, exclusive_end) byte offsets in the original
    # expression string; populated by the tokenizer
    def position
      return nil if @start_position.nil?

      [@start_position, @end_position || @start_position + length]
    end

    def with_position(start_position, end_position = nil)
      @start_position = start_position
      @end_position = end_position || start_position + length
      self
    end

    def to_s
      raw_value || value
    end

    def length
      raw_value.to_s.length
    end

    def empty?
      length.zero?
    end

    def operator?
      is?(:operator)
    end

    def grouping?
      is?(:grouping)
    end

    def open?
      grouping? && value == :open
    end

    def close?
      grouping? && value == :close
    end

    def is?(c)
      category == c
    end

    def ==(other)
      (category.nil? || other.category.nil? || category == other.category) &&
      (value.nil?    || other.value.nil?    || value    == other.value)
    end
  end
end
