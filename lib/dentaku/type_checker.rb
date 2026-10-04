require_relative 'type_conflict'
require_relative 'type_signature'

module Dentaku
  class TypeChecker
    def initialize(calculator: nil, registry: nil, case_sensitive: false)
      @registry = registry || calculator&.instance_variable_get(:@function_registry)
      @case_sensitive = case_sensitive
    end

    def check(node, declarations = {})
      @conflicts = []
      @scope = flatten_declarations(declarations)
      type = check_node(node)
      @conflicts.uniq! { |conflict| [conflict.message, conflict.actual, conflict.range] }
      TypeCheckResult.new(type, @conflicts)
    end

    private

    def check_node(node)
      return Dentaku::Types.union(*node.map { |item| check_node(item) }) if node.is_a?(::Array)

      infer(node)
    end

    def flatten_declarations(declarations)
      flatten_type_hash(declarations)
    end

    def flatten_type_hash(hash, prefix = [])
      result = {}
      hash.each do |key, value|
        path = prefix + [key.to_s]
        if value.is_a?(::Hash) && !type_declaration?(value)
          result.merge!(flatten_type_hash(value, path))
        else
          result[path_key(path)] = Dentaku::Types.normalize(declared_type(value))
        end
      end
      result
    end

    def path_key(path)
      key = path.join('.')
      standardize(key)
    end

    def declared_type(value)
      return Dentaku::Types.normalize(value) unless value.is_a?(::Hash)
      return Dentaku::Types.normalize(value) if type_declaration?(value)

      { hash: value.transform_values { |child| declared_type(child) } }
    end

    def type_declaration?(value)
      value.key?(:array) || value.key?(:elements) || value.key?(:hash) || value.key?(:members)
    end

    def infer(node, scope = @scope)
      case node
      when AST::Nil then :nil
      when AST::Literal then node.type
      when AST::Identifier then identifier_type(node, scope)
      when AST::Grouping then infer(node.instance_variable_get(:@node), scope)
      when AST::Array then array_type(node, scope)
      when AST::Access then access_type(node, scope)
      when AST::If then if_type(node, scope)
      when AST::Case then case_type(node, scope)
      when AST::Pluck then pluck_type(node, scope)
      when AST::Enum then enum_type(node, scope)
      when AST::Reduce then reduce_type(node, scope)
      when AST::Function
        function_name(node) == 'switch' ? switch_type(node, scope) : function_type(node, scope)
      when AST::Duration then :duration
      when AST::Count then :numeric
      when AST::Arithmetic then arithmetic_type(node, scope)
      when AST::Bitwise then binary_numeric_type(node, scope)
      when AST::Comparator then comparator_type(node, scope)
      when AST::Combinator then combinator_type(node, scope)
      when AST::CaseSwitchVariable
        infer(node.instance_variable_get(:@node), scope)
      when AST::CaseWhen, AST::CaseThen, AST::CaseElse
        infer(node.instance_variable_get(:@node), scope)
      when AST::CaseConditional
        Dentaku::Types.union(infer(node.then, scope))
      else
        node.respond_to?(:type) ? Dentaku::Types.normalize(node.type) : :unknown
      end
    end

    def identifier_type(node, scope)
      key = standardize(node.identifier)
      return scope.fetch(key) if scope.key?(key)

      :unknown
    end

    def array_type(node, scope)
      elements = node.instance_variable_get(:@elements)
      types = elements.map { |element| infer(element, scope) }
      { array: types.empty? ? :unknown : Dentaku::Types.union(*types) }
    end

    def access_type(node, scope)
      structure_type = infer(node.instance_variable_get(:@structure), scope)
      index_node = node.instance_variable_get(:@index)
      index_type = infer(index_node, scope)

      result = Dentaku::Types.members(structure_type).map do |member|
        access_member_type(member, index_node, index_type, node)
      end.uniq
      Dentaku::Types.union(*result)
    end

    def access_member_type(member, index_node, index_type, node)
      return :unknown if member == :unknown

      if member.is_a?(::Hash) && member.key?(:array)
        unless Dentaku::Types.include?(index_type, :numeric) || index_type == :unknown
          conflict('array index must be numeric', :numeric, index_type, index_node.source_range)
        end
        return member[:array]
      end

      if member.is_a?(::Hash) && member.key?(:hash)
        return hash_key_type(member[:hash], index_node, node, index_type)
      end

      if member == :string
        unless Dentaku::Types.include?(index_type, :numeric) || index_type == :unknown
          conflict('string index must be numeric', :numeric, index_type, index_node.source_range)
        end
        return :string
      end

      conflict('value is not indexable', [:array, :string, :hash], member, node.source_range)
      :unknown
    end

    def hash_key_type(members, index_node, node, index_type)
      return :unknown if members == :unknown
      return :unknown unless members.is_a?(::Hash)

      if index_node.is_a?(AST::Identifier)
        key = standardize(index_node.identifier)
        return members.fetch(key, :unknown)
      end

      unless Dentaku::Types.include?(index_type, :string) || Dentaku::Types.include?(index_type, :numeric) || index_type == :unknown
        conflict('hash key must be a string or number', [:string, :numeric], index_type, node.instance_variable_get(:@index).source_range)
      end
      :unknown
    end

    def if_type(node, scope)
      predicate_type = infer(node.predicate, scope)
      expect_predicate(predicate_type, node.predicate)
      Dentaku::Types.union(infer(node.left, scope), infer(node.right, scope))
    end

    def expect_predicate(type, node)
      return if type == :unknown
      return if Dentaku::Types.members(type).all? { |member| %i[logical nil unknown].include?(member) }

      conflict('predicate must be logical', :logical, type, node.source_range)
    end

    def case_type(node, scope)
      infer(node.switch.node, scope)
      branch_types = node.conditions.map do |condition|
        infer(condition.when.node, scope)
        infer(condition.then.node, scope)
      end

      branch_types << infer(node.else.node, scope) if node.else
      Dentaku::Types.union(*branch_types)
    end

    def enum_type(node, scope)
      collection_node, item_node, expression_node = node.args
      collection_type = infer(collection_node, scope)
      item_type = Dentaku::Types.element_type(collection_type)
      unless Dentaku::Types.array?(collection_type) || collection_type == :unknown
        conflict('enumeration collection must be an array', { array: :any }, collection_type, collection_node.source_range)
      end

      local_scope = scope.merge(standardize(item_node.identifier) => item_type)
      expression_type = infer(expression_node, local_scope)
      enum_result_type(node, collection_type, expression_type)
    end

    def enum_result_type(node, collection_type, expression_type)
      case node
      when AST::Map then { array: expression_type }
      when AST::Filter then collection_type
      when AST::All, AST::Any
        expect_predicate(expression_type, node.args[2])
        :logical
      else
        :unknown
      end
    end

    def pluck_type(node, scope)
      collection_node, key_node, default_node = node.args
      collection_type = infer(collection_node, scope)
      unless Dentaku::Types.array?(collection_type) || collection_type == :unknown
        conflict('PLUCK collection must be an array', { array: :hash }, collection_type, collection_node.source_range)
      end

      element_type = Dentaku::Types.element_type(collection_type)
      key_type = key_node.is_a?(AST::Identifier) ? hash_member_type(element_type, key_node.identifier) : :unknown
      default_type = default_node ? infer(default_node, scope) : :nil
      { array: Dentaku::Types.union(key_type, default_type) }
    end

    def hash_member_type(type, path)
      target = type
      path.to_s.split('.').each do |segment|
        return :unknown unless target.is_a?(::Hash) && target.key?(:hash) && target[:hash].is_a?(::Hash)

        target = target[:hash].fetch(standardize(segment), :unknown)
      end
      target
    end

    def reduce_type(node, scope)
      collection_node, memo_node, item_node, expression_node = node.args
      initial_node = node.args[4]
      collection_type = infer(collection_node, scope)
      item_type = Dentaku::Types.element_type(collection_type)
      unless Dentaku::Types.array?(collection_type) || collection_type == :unknown
        conflict('enumeration collection must be an array', { array: :any }, collection_type, collection_node.source_range)
      end

      memo_type = initial_node ? infer(initial_node, scope) : item_type
      local_scope = scope.merge(
        standardize(memo_node.identifier) => Dentaku::Types.union(memo_type),
        standardize(item_node.identifier) => item_type
      )
      infer(expression_node, local_scope)
    end

    def arithmetic_type(node, scope)
      left = infer(node.left, scope)
      right = infer(node.right, scope)
      conflict_count = @conflicts.length
      operator = node.operator
      result = arithmetic_pair_result(node, operator, left, right)
      return result unless result.nil?
      return :unknown if uses_special_arithmetic_type?(operator, left, right)

      expect_numeric_operands(node, left, right)
      return :unknown if @conflicts.length > conflict_count

      :numeric
    end

    def arithmetic_pair_result(node, operator, left, right)
      left_members = Dentaku::Types.members(left)
      right_members = Dentaku::Types.members(right)
      pairs = left_members.product(right_members)
      concrete_pairs = pairs.reject { |l, r| l == :unknown || r == :unknown }
      return :unknown if concrete_pairs.empty?

      results = concrete_pairs.map { |l, r| arithmetic_member_result(operator, l, r) }
      return Dentaku::Types.union(*results.compact) if results.none?(&:nil?)

      invalid = concrete_pairs.select { |l, r| arithmetic_member_result(operator, l, r).nil? }
      invalid.each { |l, r| report_arithmetic_pair(node, operator, l, r) }
      nil
    end

    def arithmetic_member_result(operator, left, right)
      case operator
      when :+ then addition_result(left, right)
      when :- then subtraction_result(left, right)
      when :* then multiplication_result(left, right)
      else
        :numeric if left == :numeric && right == :numeric
      end
    end

    def addition_result(left, right)
      return { array: Dentaku::Types.union(Dentaku::Types.element_type(left), Dentaku::Types.element_type(right)) } if array_member?(left) && array_member?(right)
      return :numeric if left == :numeric && right == :numeric
      return :datetime if left == :datetime && %i[numeric duration].include?(right)
    end

    def subtraction_result(left, right)
      return { array: Dentaku::Types.element_type(left) } if array_member?(left) && array_member?(right)
      return :numeric if left == :numeric && right == :numeric
      return :numeric if left == :datetime && right == :datetime
      return :datetime if left == :datetime && %i[numeric duration].include?(right)
    end

    def multiplication_result(left, right)
      return :numeric if left == :numeric && right == :numeric
      return Dentaku::Types.element_type(left) == :unknown ? { array: :unknown } : left if array_member?(left) && right == :numeric
    end

    def array_member?(member)
      member.is_a?(::Hash) && member.key?(:array)
    end

    def report_arithmetic_pair(node, operator, left, right)
      case operator
      when :+ then report_addition_pair(node, left, right)
      when :- then report_subtraction_pair(node, left, right)
      when :* then report_multiplication_pair(node, left, right)
      else
        conflict('operand must be numeric', :numeric, left, node.left.source_range) unless left == :numeric
        conflict('operand must be numeric', :numeric, right, node.right.source_range) unless right == :numeric
      end
    end

    def report_addition_pair(node, left, right)
      if array_member?(left)
        conflict('array concatenation requires an array', { array: :any }, right, node.right.source_range) unless array_member?(right)
      elsif array_member?(right)
        conflict('array concatenation requires an array', { array: :any }, left, node.left.source_range)
      elsif left == :datetime
        conflict('date addition requires a number or duration', [:numeric, :duration], right, node.right.source_range) unless %i[numeric duration].include?(right)
      elsif right == :datetime
        conflict('date addition requires a date on the left', :datetime, left, node.left.source_range) unless left == :datetime
      else
        conflict('operand must be numeric', :numeric, left, node.left.source_range) unless left == :numeric
        conflict('operand must be numeric', :numeric, right, node.right.source_range) unless right == :numeric
      end
    end

    def report_subtraction_pair(node, left, right)
      if array_member?(left)
        conflict('array subtraction requires an array', { array: :any }, right, node.right.source_range) unless array_member?(right)
      elsif array_member?(right)
        conflict('array subtraction requires an array on both sides', { array: :any }, left, node.left.source_range)
      elsif left == :datetime
        conflict('date subtraction requires a date, number, or duration', [:datetime, :numeric, :duration], right, node.right.source_range) unless %i[datetime numeric duration].include?(right)
      else
        conflict('operand must be numeric', :numeric, left, node.left.source_range) unless left == :numeric
        conflict('operand must be numeric', :numeric, right, node.right.source_range) unless right == :numeric
      end
    end

    def report_multiplication_pair(node, left, right)
      if array_member?(left)
        conflict('array repetition requires a number', :numeric, right, node.right.source_range) unless right == :numeric
      elsif array_member?(right)
        conflict('array repetition requires the array on the left', { array: :any }, left, node.left.source_range)
      else
        conflict('operand must be numeric', :numeric, left, node.left.source_range) unless left == :numeric
        conflict('operand must be numeric', :numeric, right, node.right.source_range) unless right == :numeric
      end
    end

    def uses_special_arithmetic_type?(operator, left, right)
      members = Dentaku::Types.members(left) + Dentaku::Types.members(right)
      members.any? { |member| %i[datetime duration].include?(member) || array_member?(member) }
    end

    def expect_numeric_operands(node, left, right)
      expect_type(node.left, left, :numeric, 'operand must be numeric')
      expect_type(node.right, right, :numeric, 'operand must be numeric')
    end

    def binary_numeric_type(node, scope)
      expect_numeric_operands(node, infer(node.left, scope), infer(node.right, scope))
      :numeric
    end

    def comparator_type(node, scope)
      left = infer(node.left, scope)
      right = infer(node.right, scope)

      unless %i[== :!=].include?(node.operator)
        unless comparable?(left, right)
          conflict('ordering operands must have matching comparable types',
                   :comparable, right, node.right.source_range)
        end
      end

      :logical
    end

    def comparable?(left, right)
      return true if left == :unknown || right == :unknown

      left = Dentaku::Types.members(left).reject { |member| member == :unknown || member == :nil }
      right = Dentaku::Types.members(right).reject { |member| member == :unknown || member == :nil }
      return true if left.empty? || right.empty?

      categories(left).intersection(categories(right)).any?
    end

    def categories(types)
      types.flat_map do |type|
        if type.is_a?(::Hash) && type.key?(:array)
          [[:array, type[:array]]]
        elsif type.is_a?(::Hash) && type.key?(:hash) || type == :hash
          [:hash]
        else
          [type]
        end
      end
    end

    def combinator_type(node, scope)
      [node.left, node.right].each do |operand|
        type = infer(operand, scope)
        next if type == :unknown
        next if Dentaku::Types.members(type).all? { |member| %i[logical nil unknown].include?(member) }

        conflict('logical operator requires a logical value', :logical, type, operand.source_range)
      end
      :logical
    end

    def switch_type(node, scope)
      _value, *pairs_and_default = node.args
      result_nodes = pairs_and_default.each_slice(2).map(&:last).compact
      result_nodes << node.args.last if node.args.length.even?
      Dentaku::Types.union(*result_nodes.map { |branch| infer(branch, scope) })
    end

    def function_type(node, scope)
      argument_types = node.args.map { |argument| infer(argument, scope) }
      name = function_name(node)
      signatures = @registry && @registry.get_signatures(name)
      return builtin_return_type(node, argument_types, scope) if signatures.nil?

      resolve_signatures(node, Array(signatures), argument_types)
    end

    def builtin_return_type(node, argument_types, scope)
      case node
      when AST::Xor, AST::Not
        node.args.each { |argument| expect_type(argument, infer(argument, scope), [:logical, :nil], 'argument must be logical') }
        :logical
      when AST::StringFunctions::Len, AST::StringFunctions::Find then :numeric
      when AST::StringFunctions::Contains then :logical
      when AST::StringFunctions::Base then :string
      else
        declared = node.type
        declared.nil? ? :unknown : Dentaku::Types.normalize(declared)
      end
    end

    def resolve_signatures(node, signatures, argument_types)
      signatures = signatures.map { |signature| TypeSignature.normalize(signature) }
      arity_matches = signatures.select { |signature| signature.arity_match?(argument_types.length) }

      if arity_matches.empty?
        conflict('function has no matching signature', signature_summary(signatures), argument_types, node.source_range)
        return Dentaku::Types.union(*signatures.map(&:return_type))
      end

      selected = arity_matches.select { |signature| signature_accepts?(signature, argument_types) }
      potentially_matched = arity_matches.select { |signature| signature_possibly_matches?(signature, argument_types) }
      any_unknown = argument_types.any? { |type| Dentaku::Types.all_unknown?(type) }

      if selected.length > 1 && !any_unknown
        conflict('function signature is ambiguous', signature_summary(selected), argument_types, node.source_range)
      elsif selected.one?
        return selected.first.return_type
      elsif potentially_matched.length > 1 && !any_unknown
        conflict('function signature is ambiguous', signature_summary(potentially_matched), argument_types, node.source_range)
      elsif !any_unknown
        conflict('function has no matching signature', signature_summary(arity_matches), argument_types, node.source_range)
      end


      matched = if selected.any?
                  selected
                elsif potentially_matched.any?
                  potentially_matched
                else
                  arity_matches
                end
      return :unknown if matched.empty?

      Dentaku::Types.union(*matched.map(&:return_type))
    end

    def signature_accepts?(signature, argument_types)
      fixed, variadic = signature.argument_types(argument_types)
      return false unless fixed.length <= argument_types.length
      return false unless fixed.each_with_index.all? { |expected, index| Dentaku::Types.accept?(argument_types[index], expected) }

      argument_types[fixed.length..].all? { |actual| Dentaku::Types.accept?(actual, signature.variadic_type) }
    end

    def signature_possibly_matches?(signature, argument_types)
      fixed, _variadic = signature.argument_types(argument_types)
      return false unless fixed.length <= argument_types.length
      return false unless fixed.each_with_index.all? { |expected, index| Dentaku::Types.possible?(argument_types[index], expected) }

      argument_types[fixed.length..].all? { |actual| Dentaku::Types.possible?(actual, signature.variadic_type) }
    end

    def signature_summary(signatures)
      signatures.map do |signature|
        { parameters: signature.parameters, return: signature.return_type }
      end
    end

    def function_name(node)
      name = node.source_token&.value || node.class.name.to_s.split('::').last
      name.to_s.downcase
    rescue StandardError
      node.source_token&.value&.to_s
    end

    def expect_type(node, actual, expected, message)
      return if Dentaku::Types.accept?(actual, expected)

      conflict(message, expected, actual, node.source_range)
    end

    def conflict(message, expected, actual, range)
      @conflicts << TypeConflict.new(
        message: message,
        expected: expected,
        actual: actual,
        range: range
      )
    end

    def standardize(value)
      value = value.to_s
      @case_sensitive ? value : value.downcase
    end
  end
end
