module Dentaku
  class SourcePosition
    attr_reader :offset, :line, :column

    def self.from_offset(source, offset)
      source = source.to_s
      prefix = source[0, offset].to_s
      line = prefix.count("\n") + 1
      newline = prefix.rindex("\n")
      column = newline.nil? ? prefix.length + 1 : prefix[newline + 1, prefix.length - newline - 1].length + 1
      new(offset, line, column)
    end

    def initialize(offset, line = 1, column = offset.to_i + 1)
      @offset = offset
      @line = line
      @column = column
    end

    def to_h
      { offset: offset, line: line, column: column }
    end

    def ==(other)
      other.is_a?(self.class) &&
        offset == other.offset &&
        line == other.line &&
        column == other.column
    end
    alias_method :eql?, :==

    def hash
      [self.class, offset, line, column].hash
    end
  end

  class SourceRange
    attr_reader :start_pos, :end_pos

    def self.from_offsets(source, start_offset, end_offset)
      new(
        SourcePosition.from_offset(source, start_offset),
        SourcePosition.from_offset(source, end_offset)
      )
    end

    def initialize(start_pos, end_pos = start_pos)
      @start_pos = start_pos
      @end_pos = end_pos
    end

    def start_offset
      start_pos.offset
    end

    def end_offset
      end_pos.offset
    end

    def to_h
      {
        start: start_pos.to_h,
        end: end_pos.to_h,
        start_offset: start_offset,
        end_offset: end_offset
      }
    end

    def ==(other)
      other.is_a?(self.class) &&
        start_pos == other.start_pos &&
        end_pos == other.end_pos
    end
    alias_method :eql?, :==

    def hash
      [self.class, start_pos, end_pos].hash
    end
  end
end
