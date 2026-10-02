require_relative '../function'
require_relative '../../exceptions'

module Dentaku
  module AST
    class ShortCircuitLogical < Function
      def self.min_param_count
        0
      end

      def self.max_param_count
        Float::INFINITY
      end

      def type
        :logical
      end

      def value(context = {})
        if args.empty?
          raise Dentaku::ArgumentError.for(
            :too_few_arguments,
            function_name: function_name, expected: 1.., actual: 0
          )
        end

        return resumable_value(context) if resumable_session?(context)

        first_unbound = nil

        args.each do |arg|
          begin
            value = arg.value(context)
          rescue UnboundVariableError => error
            first_unbound ||= error
            next
          end

          validate(value)
          return short_circuit_value if decisive?(value)
        end

        raise first_unbound if first_unbound

        final_value
      end

      def dependencies(context = {})
        return super.uniq if static_mode?(context)

        pending = []

        args.each do |arg|
          arg_dependencies = arg.dependencies(context)
          if arg_dependencies.any?
            pending.concat(arg_dependencies)
            next
          end

          next unless arg.pure?

          value = arg.value(context)
          return [] if decisive?(value)
        end

        pending.uniq
      rescue Dentaku::Error
        super.uniq
      end

      private

      def validate(value)
        return if value == true || value == false || value.nil?

        raise Dentaku::ArgumentError.for(
          :incompatible_type,
          function_name: function_name, expected: :logical, actual: value
        )
      end

      def decisive?(_value)
        raise NotImplementedError
      end

      def short_circuit_value
        raise NotImplementedError
      end

      def final_value
        raise NotImplementedError
      end

      def function_name
        self.class.name.to_s.split('::').last.sub(/Function\z/, '').upcase
      end

      def resumable_session?(context)
        context.key?(Dentaku::CalculationSession::SESSION_KEY)
      end

      def resumable_value(context)
        session = context.fetch(Dentaku::CalculationSession::SESSION_KEY)
        pending = ::Array.new(args.length)

        args.each_with_index do |arg, index|
          unless prunable_without_side_effect?(arg, context)
            pending[index] = false
            next
          end

          fiber, outcome = session.try_probe(arg, context)
          next unless fiber

          if fiber.alive?
            pending[index] = [fiber, outcome]
            next
          end

          validate(outcome)
          return short_circuit_value if decisive?(outcome)
        end

        args.each_with_index do |arg, index|
          state = pending[index]
          value =
            if state.is_a?(::Array)
              fiber, outcome = state
              session.await_probe(fiber, outcome)
            else
              arg.value(context)
            end

          validate(value)
          return short_circuit_value if decisive?(value)
        end

        final_value
      end

      def prunable_without_side_effect?(node, context)
        !node.send(:side_effect?, context) && node.dependencies(context).empty?
      end
    end

    class AndFunction < ShortCircuitLogical
      private

      def decisive?(value)
        !value
      end

      def short_circuit_value
        false
      end

      def final_value
        true
      end
    end

    class OrFunction < ShortCircuitLogical
      private

      def decisive?(value)
        !!value
      end

      def short_circuit_value
        true
      end

      def final_value
        false
      end
    end
  end
end
