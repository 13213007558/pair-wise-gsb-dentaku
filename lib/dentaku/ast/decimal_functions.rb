module Dentaku
  module AST
    module DecimalFunctions
      SUPPORTED = %i[abs avg max min mul round rounddown roundup sum].freeze

      def self.supported?(name)
        SUPPORTED.include?(name.to_s.downcase.to_sym)
      end

      def self.call(name, execution, args)
        case name.to_s.downcase.to_sym
        when :abs then execution.abs(args.fetch(0))
        when :avg then execution.average(flatten(args))
        when :max then execution.max(flatten(args))
        when :min then execution.min(flatten(args))
        when :mul then execution.product(flatten(args))
        when :round then execution.round(args.fetch(0), args.fetch(1, 0))
        when :rounddown then execution.rounddown(args.fetch(0), args.fetch(1, 0))
        when :roundup then execution.roundup(args.fetch(0), args.fetch(1, 0))
        when :sum then execution.sum(flatten(args))
        end
      end

      def self.flatten(args)
        args.flatten
      end
    end
  end
end
