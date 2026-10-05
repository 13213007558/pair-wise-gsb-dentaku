require_relative 'function'
require 'dentaku/expression_function_runtime'

module Dentaku
  module AST
    # Base class for functions declared as Dentaku expressions via
    # Calculator#define_function. Every (re)definition builds a fresh
    # subclass that carries its ExpressionFunctionDefinition, so formulas
    # compiled before a redefinition keep evaluating the version they
    # were compiled against.
    class ExpressionFunction < Function
      class << self
        attr_accessor :definition

        def name
          "Dentaku::AST::ExpressionFunction::#{definition.label}"
        end

        def to_s
          name
        end

        def inspect
          name
        end

        def min_param_count
          definition.required_param_count
        end

        def max_param_count
          definition.parameters.length
        end

        def volatile?
          !definition.pure?
        end
      end

      def name
        self.class.definition.name.to_s.upcase
      end

      def value(context = {})
        definition = self.class.definition
        runtime = ExpressionFunctionRuntime.fetch(context)
        runtime.enter(definition)

        begin
          definition.body.value(definition.child_context(context, args))
        rescue Dentaku::Error => e
          # the innermost frame owns the longest chain; outer frames of
          # the same failure leave it untouched
          e.call_chain ||= runtime.call_stack.dup
          raise
        ensure
          runtime.exit
        end
      end

      private

      def compute_pure?
        args.all?(&:pure?) && self.class.definition.pure?
      end
    end

    # Stands in for a function that is referenced from an expression
    # function body before it is defined (forward references, direct
    # recursion, mutual recursion). The target is resolved against the
    # calculator's function registry at evaluation time, so it always
    # binds the version current when the call runs.
    class LateBoundFunction < Function
      class << self
        attr_reader :function_name, :registry

        def build(function_name, registry)
          Class.new(self) do
            @function_name = function_name.to_s
            @registry = registry
          end
        end

        def name
          suffix = @function_name ? "(#{@function_name})" : ""
          "Dentaku::AST::LateBoundFunction#{suffix}"
        end

        def to_s
          name
        end

        def inspect
          name
        end

        def min_param_count
          0
        end

        def max_param_count
          Float::INFINITY
        end

        # the target is unknown at parse time, so dependency resolution
        # must never evaluate this node
        def volatile?
          true
        end
      end

      def name
        self.class.function_name.upcase
      end

      def value(context = {})
        function_name = self.class.function_name
        klass = self.class.registry.get(function_name)
        raise ParseError.for(:undefined_function, function_name: function_name) if klass.nil?

        validate_arity!(klass, function_name)
        klass.new(*args).value(context)
      end

      private

      # the parser checks arities for statically known functions; for
      # late-bound calls the check has to happen when the target resolves
      def validate_arity!(klass, function_name)
        given = args.length
        min = klass.arity || (klass.respond_to?(:min_param_count) ? klass.min_param_count : nil)
        max = klass.arity || (klass.respond_to?(:max_param_count) ? klass.max_param_count : nil)

        if min && given < min
          raise Dentaku::ArgumentError.for(:too_few_arguments, function_name: function_name, expected: min, actual: given)
        elsif max && given > max
          raise Dentaku::ArgumentError.for(:wrong_number_of_arguments, function_name: function_name, expected: max, actual: given)
        end
      end
    end

  end
end
