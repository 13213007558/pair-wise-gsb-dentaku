module Dentaku
  module AST
    class FunctionRegistry < Hash
      def get(name)
        name = function_name(name)
        return self[name] if has_key?(name)
        return default[name] if default.has_key?(name)
        nil
      end

      def register(name, type, implementation, callback = nil, volatile: false, decimal: nil,
                   decimal_implementation: nil)
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

          def self.decimal=(decimal)
            @decimal = decimal
          end

          def self.decimal?
            @decimal == true
          end

          def self.decimal_implementation=(implementation)
            @decimal_implementation = implementation
          end

          def self.decimal_implementation
            @decimal_implementation
          end

          def self.arity
            parameters = public_parameters
            return nil if parameters.any? { |type, _name| %i[opt rest].include?(type) }

            parameters.count
          end

          def self.min_param_count
            public_parameters.count { |type, _name| type == :req }
          end

          def self.max_param_count
            parameters = public_parameters
            return Float::INFINITY if parameters.any? { |type, _name| type == :rest }

            parameters.count { |type, _name| %i[req opt].include?(type) }
          end

          def self.public_parameters
            @implementation.parameters
          end

          def value(context = {})
            args = @args.map { |a| a.value(context) }
            decimal_context = Dentaku.current_decimal_context
            if decimal_context && self.class.decimal?
              self.class.decimal_implementation.call(decimal_context, *args)
            elsif decimal_context && %i[numeric list].include?(self.class.type)
              function_name = self.class.name.to_s.split('::').last.to_s.upcase
              raise Dentaku::DecimalUnsupportedFunctionError.new(function_name)
            else
              self.class.implementation.call(*args)
            end
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
        function.decimal = decimal
        function.decimal_implementation = decimal_implementation
        if decimal && function.decimal_implementation.nil?
          raise ::ArgumentError, 'decimal functions require a decimal_implementation'
        end

        self[function_name(name)] = function
      end

      def register_class(name, function_class)
        self[function_name(name)] = function_class
      end

      def default
        self.class.default
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
