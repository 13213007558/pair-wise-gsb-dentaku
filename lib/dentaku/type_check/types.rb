module Dentaku
  module TypeCheck
    # ground types the checker understands
    PRIMITIVE_TYPES = %i[numeric logical string datetime duration nil].freeze

    # aliases accepted in user-provided declarations
    TYPE_ALIASES = {
      bool: :logical, boolean: :logical,
      date: :datetime, time: :datetime,
      integer: :numeric, float: :numeric, number: :numeric,
      null: :nil
    }.freeze

    def self.primitive_name(name)
      name = name.to_s.downcase.to_sym
      name = TYPE_ALIASES.fetch(name, name)
      PRIMITIVE_TYPES.include?(name) ? name : nil
    end

    class Primitive
      attr_reader :name

      def initialize(name)
        @name = name
      end

      def ==(other)
        other.is_a?(Primitive) && other.name == name
      end
      alias_method :eql?, :==

      def hash
        [self.class, name].hash
      end

      def to_s
        name.to_s
      end
    end

    PRIMITIVES = PRIMITIVE_TYPES.each_with_object({}) { |t, h| h[t] = Primitive.new(t) }.freeze

    def self.primitive(name)
      PRIMITIVES.fetch(primitive_name(name))
    end
    # array with element type and dimension (length) term
    class ArrayType
      attr_reader :element, :dim

      def initialize(element, dim)
        @element = element
        @dim = dim
      end

      def ==(other)
        other.is_a?(ArrayType) && other.element == element && other.dim == dim
      end
      alias_method :eql?, :==

      def hash
        [self.class, element, dim].hash
      end

      def to_s
        "array<#{element}>[#{dim}]"
      end
    end

    # a type variable: stands for a type not (yet) known. Variables created
    # for one function call are never shared with another call.
    class Var
      attr_reader :id, :label, :origin

      def initialize(id, label: nil, origin: nil)
        @id = id
        @label = label
        @origin = origin
      end

      def key
        [:t, id]
      end

      def ==(other)
        other.is_a?(Var) && other.id == id
      end
      alias_method :eql?, :==

      def hash
        key.hash
      end

      def to_s
        label ? label.to_s : "t#{id}"
      end
    end

    # a concrete array dimension
    class DimConst
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def ==(other)
        other.is_a?(DimConst) && other.value == value
      end
      alias_method :eql?, :==

      def hash
        [self.class, value].hash
      end

      def to_s
        value.to_s
      end
    end

    # a dimension variable, e.g. the shared length of INTERCEPT's arguments
    class DimVar
      attr_reader :id, :label, :origin

      def initialize(id, label: nil, origin: nil)
        @id = id
        @label = label
        @origin = origin
      end

      def key
        [:d, id]
      end

      def ==(other)
        other.is_a?(DimVar) && other.id == id
      end
      alias_method :eql?, :==

      def hash
        key.hash
      end

      def to_s
        label ? label.to_s : "d#{id}"
      end
    end

    # the type of something that cannot be known statically, e.g. a custom
    # function without a declared signature. Absorbs anything it is unified
    # with instead of conflicting.
    class Unknown
      attr_reader :notes

      def initialize(notes)
        @notes = notes
      end

      def ==(other)
        other.is_a?(Unknown)
      end
      alias_method :eql?, :==

      def hash
        self.class.hash
      end

      def to_s
        "unknown"
      end
    end
  end
end
