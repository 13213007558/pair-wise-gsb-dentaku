module Dentaku
  module TypeChecker
    # Renders resolved types for user-facing results
    module Renderer
      module_function

      def render(type)
        case type
        when Type::Scalar then type.name.to_s
        when Type::ArrayT then "array(#{render(type.element)})"
        when Type::Var then type.label.to_s
        when Type::Flex then type.id.to_s
        when Type::Any
          case type.source
          when :undeclared_variable then "unknown"
          when :untyped_function then "unknown"
          else "unknown"
          end
        else
          type.inspect
        end
      end
    end
  end
end
