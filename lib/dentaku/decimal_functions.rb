module Dentaku
  module DecimalFunctions
    def self.abs(decimal_context, numeric)
      decimal_context.cast(numeric).abs
    end

    def self.sum(decimal_context, *args)
      args.flatten.map { |arg| decimal_context.cast(arg) }
          .reduce { |result, arg| decimal_context.add(result, arg) }
    end

    def self.mul(decimal_context, *args)
      args.flatten.map { |arg| decimal_context.cast(arg) }
          .reduce { |result, arg| decimal_context.multiply(result, arg) }
    end

    def self.avg(decimal_context, *args)
      values = args.flatten
      decimal_context.divide(sum(decimal_context, *values), values.length)
    end

    def self.min(decimal_context, *args)
      args.flatten.map { |arg| decimal_context.cast(arg) }.min
    end

    def self.max(decimal_context, *args)
      args.flatten.map { |arg| decimal_context.cast(arg) }.max
    end

    def self.round(decimal_context, numeric, places = 0)
      places = NumericParser.ensure_numeric!(places || 0).to_i
      decimal_context.cast(numeric).round(places, decimal_context.rounding_mode)
    end

    def self.rounddown(decimal_context, numeric, places = 0)
      places = NumericParser.ensure_numeric!(places || 0).to_i
      decimal_context.cast(numeric).round(places, ::BigDecimal::ROUND_DOWN)
    end

    def self.roundup(decimal_context, numeric, places = 0)
      places = NumericParser.ensure_numeric!(places || 0).to_i
      decimal_context.cast(numeric).round(places, ::BigDecimal::ROUND_UP)
    end
  end
end
