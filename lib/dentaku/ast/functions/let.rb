require_relative '../function'
require_relative '../../flat_hash'
require_relative '../../exceptions'

module Dentaku
  module AST
    class Let < Function
      def self.min_param_count
        3
      end

      def self.max_param_count
        Float::INFINITY
      end

      def initialize(*args)
        super

        if args.length.even?
          raise ParseError.for(:invalid_statement),
                'LET() requires an odd number of arguments (name, value, ..., result)'
        end

        @bindings = args[0...-1].each_slice(2).to_a
        @result = args.last
        validate!
      end

      def args
        @bindings.flat_map { |name, value| [name, value] } + [@result]
      end

      def value(context = {})
        local_tree = {}
        local_exact = {}
        @bindings.each do |name_node, value_node|
          value = value_node.value(lexical_context(context, local_tree, local_exact))
          if name_node.quoted?
            local_exact[name_node.identifier] = value
          else
            deep_set(local_tree, name_node.path_segments, value)
          end
        end
        @result.value(lexical_context(context, local_tree, local_exact))
      end

      def dependencies(context = {})
        outer_scope = current_local_scope(context)
        local_scope = outer_scope + binding_identifiers
        no_eval_context = context.merge(
          LOCAL_SCOPE_KEY => local_scope,
          NO_EVALUATION_KEY => true
        )

        binding_dependencies = @bindings.map { |_, value_node| value_node.dependencies(no_eval_context) }
        (binding_dependencies.flatten + @result.dependencies(no_eval_context)).uniq
      end

      def self.validate(node, future_bindings = [], bound_bindings = [])
        ScopeValidator.validate(node, future_bindings, bound_bindings)
        node
      end

      def compute_pure?
        false
      end

      private

      def binding_identifiers
        @bindings.map(&:first)
      end

      def current_local_scope(context)
        Array(context[LOCAL_SCOPE_KEY])
      end

      def lexical_context(context, local_tree, local_exact)
        lexical = context.dup
        lexical.delete(LOCAL_SCOPE_KEY)
        lexical.delete(NO_EVALUATION_KEY)

        local_tree.each_key do |root|
          lexical.delete_if { |key, _| key.to_s == root || key.to_s.start_with?("#{root}.") }
        end

        local_exact.each_key do |name|
          lexical.delete(name)
        end

        lexical.merge(FlatHash.from_hash_with_intermediates(local_tree)).merge(local_exact)
      end

      def deep_set(hash, path, value)
        key = path.first
        if path.length == 1
          hash[key] = value
        else
          deep_set(hash[key] ||= {}, path[1..-1], value)
        end
      end

      def overlaps?(left, right)
        left.path_start_with?(right) || right.path_start_with?(left)
      end

      def parse_error(reason, node, **meta)
        ParseError.for(reason, **meta)
      end

      def location_meta(node)
        meta = {}
        meta[:line] = node.line if node.line
        meta[:column] = node.column if node.column
        meta
      end

      def validate!
        @bindings.each do |name_node, _|
          unless name_node.is_a?(Identifier)
            raise ParseError.for(:node_invalid),
                  'LET() requires binding arguments to be identifiers'
          end
        end

        binding_identifiers.each_with_index do |name_node, index|
          previous = binding_identifiers[0...index]
          conflict = previous.find { |other| overlaps?(name_node, other) }
          next unless conflict

          reason = name_node.identifier == conflict.identifier ? :duplicate_binding : :conflicting_binding
          raise parse_error(
            reason,
            name_node,
            name: name_node.identifier,
            other_name: conflict.identifier,
            **location_meta(name_node)
          )
        end
      end

    end

    class ScopeValidator
      def self.validate(node, future_bindings = [], bound_bindings = [])
        new.validate(node, future_bindings, bound_bindings)
        node
      end

      def validate(node, future_bindings, bound_bindings)
        case node
        when Let
          validate_let(node, future_bindings, bound_bindings)
        when Identifier
          invalid = future_bindings.find { |binding| node.path_start_with?(binding) }
          raise parse_error(:forward_reference, node, name: node.identifier, **location_meta(node)) if invalid
        when Enum
          validate(node.args[0], future_bindings, bound_bindings)
          enum_bindings = bound_bindings + [node.args[1]]
          enum_futures = filter_shadowed(future_bindings, enum_bindings)
          validate(node.args[2], enum_futures, enum_bindings)
        when Reduce
          binders = bound_bindings + [node.args[1], node.args[2]]
          validate(node.args[0], future_bindings, bound_bindings)
          validate(node.args[3], filter_shadowed(future_bindings, binders), binders)
          validate(node.args[4], future_bindings, bound_bindings) if node.args[4]
        when Access
          validate(node.structure, future_bindings, bound_bindings)
          validate(node.index, future_bindings, bound_bindings)
        when Array
          node.elements.each { |element| validate(element, future_bindings, bound_bindings) }
        when Grouping
          validate(node.node, future_bindings, bound_bindings)
        when Case
          validate(node.switch, future_bindings, bound_bindings)
          node.conditions.each do |condition|
            validate(condition.when, future_bindings, bound_bindings)
            validate(condition.then, future_bindings, bound_bindings)
          end
          validate(node.else, future_bindings, bound_bindings) if node.else
        when Negation
          validate(node.node, future_bindings, bound_bindings)
        when Percentage
          validate(node.left, future_bindings, bound_bindings)
        when CaseSwitchVariable, CaseWhen, CaseThen, CaseElse
          validate(node.node, future_bindings, bound_bindings)
        when Operation
          [node.left, node.right].compact.each { |child| validate(child, future_bindings, bound_bindings) }
        when Function
          node.args.each { |arg| validate(arg, future_bindings, bound_bindings) }
        end
      end

      private

      def validate_let(node, outer_future, outer_bound)
        binding_names = node.send(:binding_identifiers)
        binding_names.each_with_index do |name_node, index|
          available = binding_names[0...index]
          bound = outer_bound + available
          future = filter_shadowed(outer_future + binding_names[index..-1], bound)
          value_node = node.args[index * 2 + 1]
          validate(value_node, future, bound)
        end

        bound = outer_bound + binding_names
        validate(node.args.last, filter_shadowed(outer_future, bound), bound)
      end

      def filter_shadowed(future_bindings, bound_bindings)
        future_bindings.reject do |future|
          bound_bindings.any? { |binder| overlaps?(future, binder) }
        end
      end

      def overlaps?(left, right)
        left.path_start_with?(right) || right.path_start_with?(left)
      end

      def parse_error(reason, node, **meta)
        ParseError.for(reason, **meta)
      end

      def location_meta(node)
        meta = {}
        meta[:line] = node.line if node.line
        meta[:column] = node.column if node.column
        meta
      end
    end
  end
end
