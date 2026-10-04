require_relative 'node'
require_relative 'function_registry'

module Dentaku
  module AST
    class Function < Node
      attr_reader :args

      # @return [Integer] with the number of significant decimal digits to use.
      DIG = Float::DIG + 1

      def initialize(*args)
        @args = args
      end

      def accept(visitor)
        visitor.visit_function(self)
      end

      def dependencies(context = {})
        @args.each_with_index
             .flat_map { |a, _| a.dependencies(context) }
      end

      # volatile functions may not be evaluated during dependency
      # resolution; registry-generated classes override this per the
      # volatile: option passed at registration
      def self.volatile?
        false
      end

      def self.array_mode
        @array_mode || :elementwise
      end

      def self.get(name)
        registry.get(name)
      end

      def self.register(name, type, implementation, volatile: false, array_mode: :whole)
        registry.register(name, type, implementation, volatile: volatile, array_mode: array_mode)
      end

      def self.register_class(name, function_class)
        registry.register_class(name, function_class)
      end

      def self.registry
        @registry ||= FunctionRegistry.new
      end

      def value(context = {})
        path = context[Dentaku::ArrayValue::PATH_KEY]
        return super unless path
        return super if self.class.array_mode == :elementwise

        cache = context[Dentaku::ArrayValue::CACHE_KEY] ||= {}
        key = [self.class.name, object_id]

        unless cache.key?(key)
          cache[key] =
            begin
              [:value, super(Dentaku::ArrayValue.without_path(context))]
            rescue StandardError => error
              [:error, error]
            end
        end

        status, result = cache[key]
        raise result if status == :error

        Dentaku::ArrayValue.index_value(result, path)
      end

      private

      def compute_pure?
        !self.class.volatile? && args.all?(&:pure?)
      end
    end
  end
end
