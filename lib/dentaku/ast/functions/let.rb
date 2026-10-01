require_relative '../function'
require_relative '../../exceptions'
require_relative '../../flat_hash'

module Dentaku
  module AST
    # LET(name1, value1, name2, value2, ..., result)
    #
    # Sequential local bindings (let* semantics): each binding value is
    # evaluated exactly once per entry, in order, in a scope that sees the
    # incoming context plus all previously bound names. The result
    # expression sees every binding. Bindings never leak into the incoming
    # context, so calculator.memory is untouched on both normal and
    # exceptional exits.
    #
    # Static rules (enforced at parse time, errors report the 1-based
    # binding position):
    # - binding positions must be plain identifiers
    # - binding names may not contain dots (no nested field paths)
    # - duplicate binding names are rejected
    # - a binding value may not reference names bound by later bindings
    #   of the same LET (self/earlier names refer to the visible scope)
    #
    # Dynamic rule (enforced at evaluation time): a binding name conflicts
    # with nested field paths already in scope (e.g. binding +item+ while
    # +item.price+ is visible) and raises an error naming both.
    class Let < Function
      def self.min_param_count
        3
      end

      def self.max_param_count
        Float::INFINITY
      end

      def initialize(*args)
        super
        validate_structure!
        @bindings = args[0...-1].each_slice(2).map { |name_node, value| [name_node.identifier, value] }
        @result = args[-1]
      end

      def value(context = {})
        check_scope_conflicts(context)

        local_scope = {}
        @bindings.each do |name, expression|
          binding_value = expression.value(context.merge(local_scope))
          local_scope.merge!(FlatHash.from_hash_with_intermediates(name => binding_value))
        end

        @result.value(context.merge(local_scope))
      end

      # Free variables only: names bound by this LET are subtracted, and
      # analysis is purely static -- binding values are never evaluated to
      # compute dependencies.
      def dependencies(context = {})
        bound = []
        deps = []

        @bindings.each do |name, expression|
          deps.concat(expand_dependencies(subtract_bound(free_identifiers(expression), bound), context))
          bound << name
        end

        deps.concat(expand_dependencies(subtract_bound(free_identifiers(@result), bound), context))
        deps.uniq
      end

      def type
        @result.type
      end

      private

      def free_identifiers(expression)
        expression.dependencies(STATIC_CONTEXT)
      end

      # a bound name also covers its nested field paths (name.field)
      def subtract_bound(names, bound)
        names.reject do |name|
          bound.any? { |b| name == b || name.start_with?("#{b}.") }
        end
      end

      # mirrors Identifier#dependencies: names present in the context
      # resolve through the stored value, everything else stays free
      def expand_dependencies(names, context)
        names.flat_map do |name|
          stored = context[name] if context.key?(name)
          stored.respond_to?(:dependencies) ? stored.dependencies(context) : (context.key?(name) ? [] : [name])
        end
      end

      def check_scope_conflicts(context)
        @bindings.each do |name, _|
          conflicting = context.keys.map(&:to_s).find { |key| key.start_with?("#{name}.") }
          next unless conflicting

          raise Dentaku::BaseError,
                "LET() binding '#{name}' conflicts with nested field path '#{conflicting}' already in scope"
        end
      end

      def validate_structure!
        if @args.length.even?
          raise ParseError.for(:node_invalid),
                "LET() requires name/value pairs followed by a result expression, but got #{@args.length} arguments"
        end

        positions = {}
        binding_nodes.each_with_index do |(name_node, _), index|
          position = index + 1

          unless name_node.is_a?(Identifier)
            raise ParseError.for(:node_invalid, binding: position),
                  "LET() binding ##{position} must be an identifier"
          end

          name = name_node.identifier

          if name.include?('.')
            raise ParseError.for(:node_invalid, binding: position, name: name),
                  "LET() binding ##{position} name '#{name}' conflicts with nested field paths; bindings must be simple names"
          end

          if positions.key?(name)
            raise ParseError.for(:node_invalid, binding: position, name: name),
                  "LET() binding ##{position} duplicates '#{name}', first bound at binding ##{positions[name]}"
          end

          positions[name] = position
        end

        binding_nodes.each_with_index do |(_, value), index|
          later = positions.keys[(index + 1)..] || []
          referenced = free_identifiers(value).select do |ref|
            later.any? { |name| ref == name || ref.start_with?("#{name}.") }
          end
          next if referenced.empty?

          name = referenced.first
          raise ParseError.for(:node_invalid, binding: index + 1, name: name),
                "LET() binding ##{index + 1} references '#{name}' before it is bound (binding ##{positions[name]})"
        end
      end

      def binding_nodes
        @args[0...-1].each_slice(2)
      end
    end
  end
end

Dentaku::AST::Function.register_class(:let, Dentaku::AST::Let)
