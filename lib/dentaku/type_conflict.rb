module Dentaku
  class TypeConflict
    attr_reader :message, :expected, :actual, :range

    def initialize(message:, expected:, actual:, range:)
      @message = message
      @expected = expected
      @actual = actual
      @range = range
    end

    def location
      return nil if range.nil?

      {
        start: range.start_pos.to_h,
        end: range.end_pos.to_h
      }
    end

    def to_h
      {
        message: message,
        expected: expected,
        actual: actual,
        location: location
      }.compact
    end
  end

  class TypeCheckError < BaseError
    attr_reader :conflicts

    def initialize(conflicts)
      @conflicts = conflicts
      super(conflicts.map(&:message).join('; '))
    end
  end

  class TypeCheckResult
    attr_reader :type, :conflicts

    def initialize(type, conflicts = [])
      @type = type
      @conflicts = conflicts
    end

    def valid?
      conflicts.empty?
    end

    def errors
      conflicts.map(&:to_h)
    end
  end
end
