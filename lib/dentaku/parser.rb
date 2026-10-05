require_relative './ast'

module Dentaku
  class Parser
    AST_OPERATIONS = {
      add:      AST::Addition,
      subtract: AST::Subtraction,
      multiply: AST::Multiplication,
      divide:   AST::Division,
      pow:      AST::Exponentiation,
      negate:   AST::Negation,
      mod:      AST::Modulo,

      bitor:    AST::BitwiseOr,
      bitand:   AST::BitwiseAnd,
      bitshiftleft:  AST::BitwiseShiftLeft,
      bitshiftright: AST::BitwiseShiftRight,

      lt:       AST::LessThan,
      gt:       AST::GreaterThan,
      le:       AST::LessThanOrEqual,
      ge:       AST::GreaterThanOrEqual,
      ne:       AST::NotEqual,
      eq:       AST::Equal,

      and:      AST::And,
      or:       AST::Or,
      xor:      AST::Xor,
    }.freeze

    attr_reader :input, :output, :operations, :arities, :case_sensitive

    def initialize(tokens, options = {})
      @input             = tokens.dup
      @output            = []
      @operations        = options.fetch(:operations, [])
      @arities           = options.fetch(:arities, [])
      @function_registry = options.fetch(:function_registry, nil)
      @case_sensitive    = options.fetch(:case_sensitive, false)
      @skip_indices      = []
      @operation_tokens  = []
      @skip_type_checks  = options.fetch(:skip_type_checks, false)
    end

    def consume(count = 2, closing_token = nil)
      operation = operations.pop
      op_token = @operation_tokens.pop
      fail! :invalid_statement if operation.nil?

      output_size = output.length
      args_size = operation.arity || count
      min_size = operation.arity || operation.min_param_count || count
      max_size = operation.arity || operation.max_param_count || count

      if output_size < min_size || args_size < min_size
        expected = min_size == max_size ? min_size : min_size..max_size
        fail! :too_few_operands, operation: operation, expected: expected, actual: output_size
      end

      if (output_size > max_size && operations.empty?) || args_size > max_size
        expected = min_size == max_size ? min_size : min_size..max_size
        fail! :too_many_operands, operation: operation, expected: expected, actual: output_size
      end

      args = []
      if operation == AST::Array && output.empty?
        # special case: empty array literal '{}'
        node = operation.new
        attach_range(node, op_token, [], closing_token)
        output.push(node)
      else
        fail! :invalid_statement if output_size < args_size
        args = Array.new(args_size) { output.pop }.reverse
        node = build_node(operation, args)
        attach_range(node, op_token, args, closing_token)
        output.push(node)
      end

      if operation.respond_to?(:callback) && !operation.callback.nil?
        operation.callback.call(args)
      end
    rescue ::ArgumentError => e
      raise if e.is_a?(Dentaku::ArgumentError)
      raise Dentaku::ArgumentError.for(:invalid_value), e.message
    rescue NodeError => e
      raise if @skip_type_checks
      raise ParseError.for(:node_invalid, operation: operation, operand: e.operand, expected: e.expected, actual: e.actual), e.message
    end

    # under static analysis the AST constructors' eager operand validation
    # must not reject the tree; we still need the node so its own type rule
    # can report a located conflict. Build it without the type check by
    # bypassing the constructor and setting the fields directly.
    def build_node(operation, args)
      operation.new(*args)
    rescue NodeError
      raise unless @skip_type_checks

      node = operation.allocate
      initialize_node_without_validation(node, operation, args)
      node
    end

    def initialize_node_without_validation(node, operation, args)
      if operation <= AST::Negation
        node.instance_variable_set(:@node, args[0])
      else
        node.instance_variable_set(:@left, args[0])
        node.instance_variable_set(:@right, args[1]) if args[1]
      end
    end

    # each entry on the operation stack carries the token that introduced it
    # so the node can report a [start, finish) range in the source expression
    def push_operation(operation_class, token)
      operations.push(operation_class)
      @operation_tokens.push(token)
    end

    def attach_range(node, op_token, args, closing_token)
      starts = [op_token&.start_position] + args.map { |a| a.respond_to?(:source_range) && a.source_range&.first }
      ends = [(closing_token || op_token)&.end_position] +
             args.map { |a| a.respond_to?(:source_range) && a.source_range&.last }
      starts = starts.compact
      ends = ends.compact
      return if starts.empty? || ends.empty?

      node.source_range = [starts.min, ends.max]
    end

    def parse
      return AST::Nil.new if input.empty?

      i = 0
      while i < input.length
        if @skip_indices.include?(i)
          i += 1
          next
        end

        token = input[i]
        lookahead = input[i + 1]
        process_token(token, lookahead, i)
        i += 1
      end

      consume while operations.any?

      fail! :invalid_statement unless output.count == 1

      output.first
    end

    def operation(token)
      AST_OPERATIONS.fetch(token.value)
    end

    def function(token)
      function_registry.get(token.value)
    end

    def function_registry
      @function_registry ||= Dentaku::AST::FunctionRegistry.new
    end

    private

    def process_token(token, lookahead, index)
      case token.category
      when :datetime      then output << AST::DateTime.new(token)
      when :numeric       then output << AST::Numeric.new(token)
      when :logical       then output << AST::Logical.new(token)
      when :string        then output << AST::String.new(token)
      when :identifier    then output << AST::Identifier.new(token, case_sensitive: case_sensitive)
      when :operator, :comparator, :combinator
        handle_operator(token, lookahead)
      when :null
        output << AST::Nil.new
      when :function
        handle_function(token)
      when :case
        handle_case(token)
      when :access
        handle_access(token)
      when :array
        handle_array(token)
      when :grouping
        handle_grouping(token, lookahead, index)
      else
        fail! :not_implemented_token_category, token_category: token.category
      end
    end

    def handle_operator(token, lookahead)
      op_class = operation(token).resolve_class(lookahead)
      if op_class.right_associative?
        consume while operations.last && operations.last < AST::Operation && op_class.precedence < operations.last.precedence
      else
        consume while operations.last && operations.last < AST::Operation && op_class.precedence <= operations.last.precedence
      end
      push_operation(op_class, token)
    end

    def handle_function(token)
      func = function(token)
      fail! :undefined_function, function_name: token.value if func.nil?
      arities.push 0
      push_operation(func, token)
    end

    def handle_case(token)
      # We always operate on the innermost (most recent) CASE on the stack.
      case_index = operations.rindex(AST::Case) || -1
      token_index = case_index + 1

      case token.value
      when :open
        # Start a new CASE context.
        push_operation(AST::Case, token)
        arities.push(0)

      when :close
        # Finalize any trailing THEN/ELSE expression still on the stack.
        if operations[token_index] == AST::CaseThen
          consume_until(AST::Case)
          push_operation(AST::CaseConditional, nil)
          consume(2, token)
          arities[-1] += 1
        elsif operations[token_index] == AST::CaseElse
          consume_until(AST::Case)
          arities[-1] += 1
        end
        fail! :unprocessed_token, token_name: token.value unless operations.last == AST::Case
        consume(arities.pop.succ, token)

      when :when
        if operations[token_index] == AST::CaseThen
          # Close out previous WHEN/THEN pair.
          consume_until([AST::CaseWhen, AST::Case])
          push_operation(AST::CaseConditional, nil)
          consume(2)
          arities[-1] += 1
        elsif operations[token_index].nil? ||
              (operations[token_index] != AST::CaseWhen && operations[token_index] < AST::Operation)
          # First WHEN: fold any operators pending from an unparenthesized
          # switch expression, then finalize the switch variable.
          consume_until(AST::Case)
          push_operation(AST::CaseSwitchVariable, nil)
          consume
        end
        push_operation(AST::CaseWhen, token)

      when :then
        if operations[token_index] == AST::CaseWhen
          consume_until([AST::CaseThen, AST::Case])
        end
        push_operation(AST::CaseThen, token)

      when :else
        if operations[token_index] == AST::CaseThen
          consume_until(AST::Case)
          push_operation(AST::CaseConditional, nil)
          consume(2)
          arities[-1] += 1
        end
        push_operation(AST::CaseElse, token)

      else
        fail! :unknown_case_token, token_name: token.value
      end
    end

    def consume_until(target)
      matcher =
        case target
        when Array then ->(op) { target.include?(op) }
        else ->(op) { op == target }
        end

      consume while operations.any? && !matcher.call(operations.last)
    end

    def handle_access(token)
      case token.value
      when :lbracket
        push_operation(AST::Access, token)

      when :rbracket
        consume while operations.any? && operations.last != AST::Access
        fail! :unbalanced_bracket, token: token unless operations.last == AST::Access
        consume(2, token)
      end
    end

    def handle_array(token)
      case token.value
      when :array_start
        push_operation(AST::Array, token)
        arities.push 0

      when :array_end
        consume while operations.any? && operations.last != AST::Array
        fail! :unbalanced_bracket, token: token unless operations.last == AST::Array
        consume(arities.pop.succ, token)
      end
    end

    def handle_grouping(token, lookahead, token_index)
      case token.value
      when :open
        if lookahead && lookahead.value == :close
          # empty grouping (e.g. function with zero arguments) — we trigger consume later
          # skip to the end
          @skip_indices << token_index + 1
          arities.pop
          consume(0)
        else
          push_operation(AST::Grouping, token)
        end

      when :close
        consume while operations.any? && operations.last != AST::Grouping
        lparen = operations.pop
        @operation_tokens.pop
        fail! :unbalanced_parenthesis, token: token unless lparen == AST::Grouping
        if operations.last && operations.last < AST::Function
          consume(arities.pop.succ, token)
        end

      when :comma
        fail! :invalid_statement if arities.empty?
        arities[-1] += 1
        consume while operations.any? && operations.last != AST::Grouping && operations.last != AST::Array

      else
        fail! :unknown_grouping_token, token_name: token.value
      end
    end

    def fail!(reason, **meta)
      raise ParseError.for(reason, **meta)
    end
  end
end
