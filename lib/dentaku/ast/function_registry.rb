module Dentaku
  module AST
    class FunctionRegistry < Hash
      def get(name)
        name = function_name(name)
        return self[name] if has_key?(name)
        return default[name] if default.has_key?(name)
        nil
      end

      def register(name, type, implementation, callback = nil, volatile: false, vector_mode: :elementwise)
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

          def self.vector_mode=(vector_mode)
            @vector_mode = vector_mode
          end

          # :elementwise - the implementation receives per-position scalars
          #               and broadcasts over array arguments
          # :array      - the implementation receives the whole broadcast
          #               arrays in a single call
          def self.vector_mode
            @vector_mode || :elementwise
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
            impl = self.class.implementation
            if self.class.vector_mode == :array
              values = @args.map { |arg| arg.value(context) }
              # Whole-array functions receive the raw resolved values
              # (Ruby arrays included) and decide themselves how to consume
              # collections. No broadcasting or shape checks happen here.
              impl.call(*values)
            else
              if Dentaku::Vector.positioned?(context)
                impl.call(*@args.map { |arg| arg.value(context) })
              else
                # Validate argument shapes purely structurally before any
                # argument value (and therefore any side-effecting function
                # inside an argument) is evaluated.
                shapes = @args.map { |arg| Dentaku::Vector.infer_shape(arg, context) }
                shape = Dentaku::Tensor.broadcast_shape(*shapes)
                if shape.empty?
                  impl.call(*@args.map { |arg| arg.value(context) })
                else
                  evaluate_elementwise(shape, context, impl)
                end
              end
            end
          end

          def evaluate_elementwise(shape, context, impl)
            # Resolve arguments lazily per position through a positioned
            # context. A producer is invoked at most once per position, so
            # side effects in arguments fire exactly where the shape needs
            # their value.
            Dentaku::Vector.elementwise_ast(@args, shape, context) do |values|
              impl.call(*values)
            end
          end

          def type
            self.class.type
          end

          def tensor_shape(context = {})
            return [] if self.class.vector_mode == :array

            shapes = @args.map { |arg| Dentaku::Vector.infer_shape(arg, context) }
            Dentaku::Tensor.broadcast_shape(*shapes)
          end
        end

        function.name = name
        function.display_name = "#{Function}::#{normalize_name(name)}"

        define_class(name, function)

        function.type = type
        function.implementation = implementation
        function.callback = callback
        function.volatile = volatile
        function.vector_mode = vector_mode

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
