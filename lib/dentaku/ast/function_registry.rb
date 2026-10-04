module Dentaku
  module AST
    class FunctionRegistry < Hash
      def get(name)
        name = function_name(name)
        return self[name] if has_key?(name)
        return default[name] if default.has_key?(name)
        nil
      end

      def register(name, type, implementation, callback = nil, volatile: false, signatures: nil)
        function = Class.new(Function) do
          def self.name=(name)
            @name = name.to_s
          end

          def self.name
            @name
          end

          # only the first registration of a given name claims the constant
          # under Dentaku::AST::Function, so later ones stay anonymous and
          # would otherwise render as "#<Class:0x...>" in error messages
          def self.display_name=(display_name)
            @display_name = display_name
          end

          def self.to_s
            @display_name || super
          end

          def self.inspect
            to_s
          end

          def self.implementation=(impl)
            @implementation = impl
          end

          def self.implementation
            @implementation
          end

          def self.type=(type)
            @type = type
          end

          def self.type
            @type
          end

          def self.signatures=(signatures)
            @signatures = signatures
          end

          def self.signatures
            @signatures
          end

          def self.callback=(callback)
            @callback = callback
          end

          def self.callback
            @callback
          end

          def self.volatile=(volatile)
            @volatile = volatile
          end

          def self.volatile?
            @volatile
          end

          def self.arity
            @implementation.arity < 0 ? nil : @implementation.arity
          end

          def self.min_param_count
            @implementation.parameters.select { |type, _name| type == :req }.count
          end

          def self.max_param_count
            @implementation.parameters.select { |type, _name| type == :rest }.any? ? Float::INFINITY : @implementation.parameters.count
          end

          def value(context = {})
            args = @args.map { |a| a.value(context) }
            self.class.implementation.call(*args)
          end

          def type
            self.class.type
          end
        end

        function.name = name
        function.display_name = "#{Function}::#{normalize_name(name)}"

        define_class(name, function)

        function.type = type
        function.implementation = implementation
        function.callback = callback
        function.volatile = volatile
        function.signatures = signatures

        self[function_name(name)] = function
        register_signatures(name, signatures) if signatures
        function
      end

      def register_class(name, function_class, signatures: nil)
        self[function_name(name)] = function_class
        register_signatures(name, signatures) if signatures
      end

      def register_signatures(name, signatures)
        @signatures ||= {}
        @signatures[function_name(name)] = Array(signatures)
      end

      def get_signatures(name)
        own = defined?(@signatures) && @signatures&.dig(function_name(name))
        return own if own

        default_signatures[function_name(name)]
      end

      def default
        self.class.default
      end

      def default_signatures
        self.class.default.instance_variable_get(:@signatures) || {}
      end

      def self.default
        Dentaku::AST::Function.registry
      end

      private

      def function_name(name)
        name.to_s.downcase
      end

      def normalize_name(function_name)
        function_name.to_s.capitalize.gsub(/\W/, '_')
      end

      def define_class(function_name, function)
        class_name = normalize_name(function_name)
        return if Dentaku::AST::Function.const_defined?(class_name)

        Dentaku::AST::Function.const_set(class_name, function)
      end
    end
  end
end
