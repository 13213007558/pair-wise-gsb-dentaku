module Dentaku
  module TypeChecker
    # Raised (and caught by the checker) when two concrete types cannot be
    # unified. Carries both types plus the source sites that constrained
    # them, so an error can point back at parameters / operations.
    class TypeConflict < StandardError
      attr_reader :left, :right, :sites

      def initialize(left, right, sites = [])
        @left = left
        @right = right
        @sites = sites
        super("type conflict: #{Renderer.render(left)} vs #{Renderer.render(right)}")
      end
    end

    # A use of a type at a particular place in a formula: either a node
    # range or an explicit label (e.g. "argument 2 of FOO").
    Use = Struct.new(:range, :label, :formula) do
      def key
        [formula, range&.first, range&.last, label]
      end
    end

    # Union-find-ish substitution over Flex variables with evidence
    # tracking. Every binding stores the sites that forced it; when a
    # binding later disagrees, all contributing sites are reported.
    class Unifier
      attr_reader :subst, :evidence

      def initialize
        @subst = {}
        @evidence = {}
      end

      def resolve(type)
        case type
        when Type::Flex
          bound = @subst[type.id]
          bound ? resolve(bound) : type
        when Type::ArrayT
          Type.array(resolve(type.element))
        else
          type
        end
      end

      def unify(left, right, sites = [])
        left = resolve(left)
        right = resolve(right)

        return self if equal_types?(left, right)

        if Type.flex?(left)
          bind(left, right, sites)
        elsif Type.flex?(right)
          bind(right, left, sites)
        elsif Type.any?(left) || Type.any?(right)
          absorb_any(left, right, sites)
        elsif Type.array?(left) && Type.array?(right)
          unify(left.element, right.element, sites)
        elsif compatible_scalars?(left, right)
          self
        else
          raise TypeConflict.new(left, right, sites_for(left, right, sites))
        end

        self
      end

      # sites that contributed to constraining a type, plus the new ones
      def sites_for(left, right, sites)
        ids = variable_ids(left) + variable_ids(right)
        gathered = ids.flat_map { |id| @evidence[id] || [] }
        (gathered + sites).uniq(&:key)
      end

      def bind(flex, type, sites)
        existing = @subst[flex.id]
        if existing
          unify(existing, type, sites)
        else
          @subst[flex.id] = type
          attach_evidence(flex.id, sites)
          if Type.flex?(type)
            # evidence should also be reachable through the target id
            attach_evidence(type.id, sites)
          end
        end
        self
      end

      def attach_evidence(id, sites)
        @evidence[id] ||= []
        @evidence[id].concat(sites)
        @evidence[id].uniq!(&:key)
      end

      # unknown never forces a conflict; remember where it participated so
      # the final result can explain what is still undetermined
      def absorb_any(left, right, sites)
        if Type.any?(left)
          attach_any(left, sites)
          if Type.flex?(right)
            @subst[right.id] = left unless @subst.key?(right.id)
            attach_evidence(right.id, sites)
          end
        else
          absorb_any(right, left, sites)
        end
        self
      end

      def attach_any(any, sites)
        @any_sites ||= {}
        key = [any.source, any.range&.first, any.range&.last]
        @any_sites[key] ||= { any: any, sites: [] }
        @any_sites[key][:sites].concat(sites)
        @any_sites[key][:sites].uniq!(&:key)
      end

      def unknowns
        (@any_sites || {}).values
      end

      def equal_types?(left, right)
        return true if left == right

        Type.array?(left) && Type.array?(right) &&
          equal_types?(left.element, right.element)
      end

      # integer is treated as numeric elsewhere; at this layer scalars
      # only unify with themselves or with the wider numeric family
      def compatible_scalars?(left, right)
        return false unless left.is_a?(Type::Scalar) && right.is_a?(Type::Scalar)

        names = [left.name, right.name].sort
        names == %i[integer numeric]
      end

      private

      def variable_ids(type)
        case type
        when Type::Flex then [type.id]
        when Type::ArrayT then variable_ids(type.element)
        else []
        end
      end
    end
  end
end
