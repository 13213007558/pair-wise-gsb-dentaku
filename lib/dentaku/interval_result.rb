require_relative 'interval'

module Dentaku
  # Outcome of evaluating one expression over interval inputs.
  #
  # +interval+ is guaranteed to contain every value the expression can take
  # for admissible inputs. +notes+ records every place the enclosure was
  # widened (indeterminate branches, unknown custom-function rules,
  # unsupported operations). +undefined_points+ lists concrete input values
  # excluded from the image, e.g. a divisor that crosses zero.
  class IntervalResult
    attr_reader :interval, :notes, :undefined_points

    def initialize(interval, notes: [], undefined_points: [])
      @interval = interval
      @notes = notes.dup
      @undefined_points = undefined_points.dup
    end

    def low
      interval.low
    end

    def high
      interval.high
    end

    def unbounded?
      interval.unbounded?
    end

    def widened?
      !notes.empty?
    end

    def exact?
      !widened?
    end

    def merge(other, note = nil)
      merged_notes = merge_notes(notes, other.notes, note)
      IntervalResult.new(
        Interval.hull(interval, other.interval),
        notes: merged_notes,
        undefined_points: (undefined_points + other.undefined_points).uniq.sort
      )
    end

    def with_notes(*new_notes)
      IntervalResult.new(interval, notes: merge_notes(notes, new_notes),
                         undefined_points: undefined_points)
    end

    def with_undefined(points)
      IntervalResult.new(interval, notes: notes,
                         undefined_points: (undefined_points + Array(points)).uniq.sort)
    end

    def map_interval
      IntervalResult.new(yield(interval), notes: notes, undefined_points: undefined_points)
    end

    def scale(factor)
      map_interval { |current| current.mul(Interval.point(factor)) }
    end

    def to_h
      {
        interval: interval,
        low: interval.low,
        high: interval.high,
        notes: notes,
        undefined_points: undefined_points
      }
    end

    def to_s
      suffix = widened? ? " (widened: #{notes.map(&:code).join(', ')})" : ''
      "#{interval}#{suffix}"
    end
    alias_method :inspect, :to_s

    # Structured explanation for a single widening decision.
    Note = Struct.new(:code, :message, :location, keyword_init: true) do
      def to_s
        location ? "#{code} @ #{location}: #{message}" : "#{code}: #{message}"
      end
    end

    def self.note(code, message, location: nil)
      Note.new(code: code, message: message, location: location)
    end

    private

    def merge_notes(*groups)
      groups.flatten.compact.uniq { |note| [note.code, note.message, note.location] }
    end
  end
end
