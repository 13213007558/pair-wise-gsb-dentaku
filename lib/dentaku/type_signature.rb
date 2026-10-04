module Dentaku
  class TypeSignature
    attr_reader :parameters, :return_type, :variadic_type

    def self.normalize(signature)
      return signature if signature.is_a?(self)

      case signature
      when Hash
        parameters = signature[:params] || signature[:parameters] || []
        return_type = signature.key?(:return) ? signature[:return] : signature[:return_type]
        new(parameters, return_type)
      else
        params, return_type = signature
        new(params || [], return_type)
      end
    end

    def initialize(parameters, return_type)
      raw_parameters = Array(parameters)
      variadic = raw_parameters.last
      if variadic.is_a?(Hash) && variadic.key?(:variadic)
        @variadic_type = Types.normalize(variadic.fetch(:variadic))
        @parameters = raw_parameters[0...-1].map { |parameter| Types.normalize(parameter) }
      else
        @parameters = raw_parameters.map { |parameter| Types.normalize(parameter) }
        @variadic_type = nil
      end
      @return_type = Types.normalize(return_type)
    end

    def arity_match?(argument_count)
      return argument_count >= parameters.length if variadic?

      argument_count == parameters.length
    end

    def variadic?
      !variadic_type.nil?
    end

    def argument_types(argument_types)
      fixed = parameters.first(argument_types.length)
      variadic = @variadic_type.nil? ? [] : argument_types[parameters.length..]
      [fixed, variadic]
    end
  end

  module Types
    BASIC_TYPES = %i[
      numeric string logical datetime nil array duration hash any unknown
    ].freeze

    def self.normalize(type)
      return :unknown if type.nil?
      return type if type == :unknown || type == :any
      return type.map { |member| normalize(member) }.uniq if type.is_a?(::Array)

      if type.is_a?(::Hash)
        if type.key?(:array) || type.key?(:elements)
          { array: normalize(type[:array] || type[:elements]) }
        elsif type.key?(:hash) || type.key?(:members)
          members = type[:hash] || type[:members]
          return :hash unless members.is_a?(::Hash)

          { hash: members.transform_values { |member| normalize(member) } }
        else
          raise ::ArgumentError, "unsupported declared type #{type.inspect}"
        end
      else
        symbol = type.to_s.to_sym
        aliases = {
          integer: :numeric, number: :numeric, float: :numeric, decimal: :numeric,
          boolean: :logical, bool: :logical,
          date: :datetime, time: :datetime, timestamp: :datetime,
          null: :nil, list: { array: :unknown }, object: :hash
        }
        normalized = symbol == :array ? { array: :unknown } : aliases.fetch(symbol, symbol)
        return normalized if normalized.is_a?(::Hash)
        raise ::ArgumentError, "unsupported declared type #{type.inspect}" unless BASIC_TYPES.include?(normalized)

        normalized
      end
    end

    def self.members(type)
      type.is_a?(::Array) ? type : [type]
    end

    def self.union(*types)
      result = types.flat_map { |type| members(normalize(type)) }.uniq
      return :unknown if result.empty?
      result.length == 1 ? result.first : result
    end

    def self.include?(type, basic_type)
      return true if type == basic_type
      members(type).include?(basic_type)
    end

    def self.array?(type)
      members(type).any? { |member| member.is_a?(::Hash) && member.key?(:array) }
    end

    def self.element_type(type)
      array_members = members(type).select { |member| member.is_a?(::Hash) && member.key?(:array) }
      return :unknown if array_members.empty?

      union(*array_members.map { |member| member[:array] })
    end

    def self.hash?(type)
      members(type).any? { |member| member == :hash || (member.is_a?(::Hash) && member.key?(:hash)) }
    end

    def self.compatible?(actual, expected)
      match(actual, expected).first
    end

    def self.possible?(actual, expected)
      match(actual, expected).last
    end

    def self.all_unknown?(type)
      members(normalize(type)) == [:unknown]
    end

    def self.match(actual, expected)
      actual = normalize(actual)
      expected = normalize(expected)
      member_matches = members(actual)
      definite = member_matches.map { |member| member_match(member, expected) }.all?
      possible = member_matches.map { |member| member_possible(member, expected) }.any?
      [definite, possible]
    end

    def self.member_match(member, expected)
      return true if expected == :any
      return false if member == :unknown

      if expected.is_a?(::Array)
        expected.any? { |candidate| member_match(member, candidate) }
      elsif member.is_a?(::Array)
        false
      elsif expected.is_a?(::Hash) && member.is_a?(::Hash)
        if expected.key?(:array) && member.key?(:array)
          possible_match(member[:array], expected[:array])
        elsif expected.key?(:hash) && (member == :hash || member.key?(:hash))
          hash_match(member, expected[:hash])
        else
          false
        end
      else
        member == expected || (expected == :hash && member == :hash)
      end
    end

    def self.possible_match(actual, expected)
      definite, possible = match(actual, expected)
      definite || possible
    end

    def self.accept?(actual, expected)
      actual = normalize(actual)
      expected = normalize(expected)
      statuses = members(actual).map { |member| member_accept(member, expected) }
      return true if statuses.all?(:unknown)

      statuses.include?(true) && statuses.all? { |status| status == true || status == :unknown }
    end

    def self.member_accept(member, expected)
      return :unknown if member == :unknown
      member_match(member, expected) ? true : false
    end

    def self.member_possible(member, expected)
      return true if expected == :any || member == :unknown

      if expected.is_a?(::Array)
        expected.any? { |candidate| member_possible(member, candidate) }
      elsif member.is_a?(::Array)
        false
      elsif expected.is_a?(::Hash) && member.is_a?(::Hash)
        if expected.key?(:array) && member.key?(:array)
          possible_match(member[:array], expected[:array])
        elsif expected.key?(:hash) && (member == :hash || member.key?(:hash))
          possible_hash_match(member, expected[:hash])
        else
          false
        end
      else
        member == expected || (expected == :hash && member == :hash)
      end
    end

    def self.hash_match(actual, expected)
      return true if expected == :unknown || actual == :hash
      return false unless actual.is_a?(::Hash) && expected.is_a?(::Hash)

      expected.all? do |key, expected_member|
        actual_member = actual[:hash].is_a?(::Hash) ? actual[:hash][key] : nil
        actual_member.nil? || member_match(actual_member, expected_member)
      end
    end

    def self.possible_hash_match(actual, expected)
      return true if expected == :unknown || actual == :hash
      return false unless actual.is_a?(::Hash) && expected.is_a?(::Hash)

      expected.all? do |key, expected_member|
        actual_member = actual[:hash].is_a?(::Hash) ? actual[:hash][key] : nil
        actual_member.nil? || member_possible(actual_member, expected_member)
      end
    end
  end
end
