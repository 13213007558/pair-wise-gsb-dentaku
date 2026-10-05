require 'spec_helper'
require 'dentaku'

describe Dentaku::TypeChecker::Checker do
  let(:calculator) { Dentaku::Calculator.new }

  def check(expr, signatures: nil, **types)
    calculator.type_check(expr, types, signatures: signatures)
  end

  describe 'literal and scalar inference' do
    it 'infers numeric literals and arithmetic' do
      result = check('1 + 2 * 3')
      expect(result).to be_ok
      expect(result.rendered_type).to eq('numeric')
    end

    it 'infers string, logical and date literals' do
      expect(check('"hi"').rendered_type).to eq('string')
      expect(check('true').rendered_type).to eq('logical')
      expect(check('2024-01-02').rendered_type).to eq('date')
    end

    it 'accepts bool/boolean/number/text aliases in declarations' do
      expect(check('a && b', a: :bool, b: :boolean)).to be_ok
      expect(check('x', x: 'number').rendered_type).to eq('numeric')
      expect(check('s', s: :text).rendered_type).to eq('string')
    end
  end

  describe 'declared variables' do
    it 'uses declared variable types' do
      expect(check('price * quantity', price: :numeric, quantity: :numeric)).to be_ok
    end

    it 'flags a string used in arithmetic and locates the operand' do
      result = check('price * 2', price: :string)
      expect(result).not_to be_ok
      expect(result.conflicts.first.message).to include('string', 'numeric')
      range = result.conflicts.first.ranges.find { |r| r == [0, 5] }
      expect(range).to eq([0, 5])
    end

    it 'leaves undeclared variables unknown without failing' do
      result = check('a + 1')
      expect(result).to be_ok
      expect(result).not_to be_fully_known
      expect(result.unknowns.map(&:reason)).to include(match(/no declared type/))
      expect(result.unknowns.first.range).to eq([0, 1])
    end
  end

  describe 'polymorphic function isolation' do
    before do
      calculator.add_function(:first, :string, ->(a) { a.first })
      calculator.add_type_signature(:first, 'array(T) -> T')
    end

    it 'instantiates type variables separately for each call' do
      strings = check('FIRST(names)', names: 'array(string)')
      numbers = check('FIRST(nums)', nums: 'array(numeric)')
      expect(strings.rendered_type).to eq('string')
      expect(numbers.rendered_type).to eq('numeric')
    end

    it 'does not share T across two calls in one formula' do
      result = check('FIRST(names) = FIRST(nums)',
                     names: 'array(string)', nums: 'array(numeric)')
      # each call is independent; the equality op then detects the mismatch
      expect(result).not_to be_ok
      message = result.conflicts.first.message
      expect(message).to include('string').and include('numeric')
    end

    it 'uses the same polymorphic function on string and numeric arrays without leaking' do
      one = check('CONCAT(FIRST(names), "!")', names: 'array(string)')
      two = check('FIRST(nums) + 1', nums: 'array(numeric)')
      expect(one).to be_ok
      expect(two).to be_ok
    end
  end

  describe 'IF branching' do
    it 'unifies both branches into a common result type' do
      expect(check('IF(flag, 1, 2)', flag: :logical).rendered_type).to eq('numeric')
      expect(check('IF(flag, "a", "b")', flag: :logical).rendered_type).to eq('string')
    end

    it 'reports conflicting branches at each branch position' do
      expr = 'IF(flag, 1, "x")'
      result = check(expr, flag: :logical)
      expect(result).not_to be_ok
      conflict = result.conflicts.first
      expect(conflict.message).to include('IF true branch').and include('IF false branch')
      expect(conflict.ranges).to include([9, 10])
      expect(conflict.ranges).to include([12, 15])
    end

    it 'requires the predicate to be logical' do
      result = check('IF(1, 2, 3)')
      expect(result).not_to be_ok
      expect(result.conflicts.first.message).to include('IF condition')
    end
  end

  describe 'arrays and dimensional constraints' do
    it 'unifies array literal element types' do
      expect(check('{1, 2, 3}').rendered_type).to eq('array(numeric)')
      expect(check('{"a", "b"}').rendered_type).to eq('array(string)')
    end

    it 'rejects mixed arrays and locates the offending element' do
      result = check('{1, "x"}')
      expect(result).not_to be_ok
      expect(result.conflicts.first.ranges).to include([4, 7])
    end

    it 'threads element types through SUM/MAP and captures dimensions' do
      expect(check('SUM({1,2,3})').rendered_type).to eq('numeric')
      expect(check('MAP(nums, n, n + 1)', nums: 'array(numeric)').rendered_type)
        .to eq('array(numeric)')
    end

    it 'rejects SUM over a string array with argument location' do
      result = check('SUM(items)', items: 'array(string)')
      expect(result).not_to be_ok
      expect(result.conflicts.first.message).to include('argument 1 of SUM')
    end

    it 'checks FILTER predicates' do
      ok = check('FILTER(nums, n, n > 0)', nums: 'array(numeric)')
      bad = check('FILTER(nums, n, n + 1)', nums: 'array(numeric)')
      expect(ok).to be_ok
      expect(bad).not_to be_ok
    end

    it 'checks array indexing element type' do
      expect(check('nums[0] + 1', nums: 'array(numeric)')).to be_ok
      expect(check('names[0] + 1', names: 'array(string)')).not_to be_ok
    end
  end

  describe 'custom functions without signatures' do
    it 'records unknown and never evaluates the function to guess a type' do
      called = false
      calculator.add_function(:mystery, :string, ->(x) { called = true; x.to_s })
      result = check('MYSTERY(x) + 1', x: :numeric)
      expect(called).to eq(false)
      expect(result).to be_ok
      expect(result).not_to be_fully_known
      unknown = result.unknowns.first
      expect(unknown.reason).to include('mystery')
      # the influence reaches the enclosing + operation
      expect(unknown.sites.map(&:label)).to include('left operand of +')
    end

    it 'still checks the arguments of an unsigned function' do
      calculator.add_function(:f, :string, ->(x) { x.to_s })
      expect(check('F("a")').unknowns.size).to eq(1)
    end
  end

  describe 'comparisons and logical operators' do
    it 'checks unary numeric operators' do
      expect(check('50%').rendered_type).to eq('numeric')
      expect(check('"x"%')).not_to be_ok
      expect(check('-a', a: :numeric)).to be_ok
    end

    it 'allows optional arguments (ROUND precision)' do
      expect(check('ROUND(x)', x: :numeric)).to be_ok
      expect(check('ROUND(x, 2)', x: :numeric)).to be_ok
    end

    it 'requires comparable operands' do
      expect(check('1 = 1')).to be_ok
      bad = check('1 = "x"')
      expect(bad).not_to be_ok
      expect(bad.conflicts.first.message).to include('left of =').and include('right of =')
    end

    it 'requires logical operands for &&' do
      expect(check('a && b', a: :logical, b: :logical)).to be_ok
      expect(check('1 && true')).not_to be_ok
    end
  end

  describe 'CASE' do
    it 'unifies switch, whens and thens' do
      expect(check('CASE x WHEN 1 THEN 2 ELSE 3 END', x: :numeric).rendered_type)
        .to eq('numeric')
    end

    it 'reports a branch type conflict' do
      result = check('CASE x WHEN 1 THEN "a" ELSE 2 END', x: :numeric)
      expect(result).not_to be_ok
      expect(result.conflicts.first.message).to include('CASE')
    end
  end

  describe 'batched connected formulas' do
    before do
      calculator.add_function(:first, :string, ->(a) { a.first })
      calculator.add_type_signature(:first, 'array(T) -> T')
    end

    it 'propagates types through the formula graph' do
      result = calculator.type_check_batch(
        { total: 'FIRST(nums)', tax: 'total * 2' },
        nums: 'array(numeric)'
      )
      expect(result).to be_ok
      expect(result.types['total'].to_s).to eq('numeric')
      expect(result.types['tax'].to_s).to eq('numeric')
    end

    it 'surfaces a conflict that only appears when formulas are connected' do
      # each formula is internally consistent in isolation; linking total:
      # FIRST(string[]) is a string, but tax treats it as numeric
      result = calculator.type_check_batch(
        { total: 'FIRST(names)', tax: 'total + 1' },
        names: 'array(string)'
      )
      expect(result).not_to be_ok
      conflict = result.conflicts.first
      expect(conflict.formula).to eq(:tax)
      expect(conflict.message).to include('string').and include('numeric')
      expect(conflict.ranges).to include([0, 5]) # "total"
    end

    it 'reports no such conflict when the polymorphic call yields numeric' do
      result = calculator.type_check_batch(
        { total: 'FIRST(nums)', tax: 'total + 1' },
        nums: 'array(numeric)'
      )
      expect(result).to be_ok
    end

    it 'keeps polymorphic calls separate even inside a batch' do
      result = calculator.type_check_batch(
        { s: 'FIRST(names)', n: 'FIRST(nums)' },
        names: 'array(string)', nums: 'array(numeric)'
      )
      expect(result).to be_ok
      expect(result.types['s'].to_s).to eq('string')
      expect(result.types['n'].to_s).to eq('numeric')
    end
  end

  describe 'signatures supplied per check' do
    it 'accepts an ad-hoc signature without registering the function' do
      calculator.add_function(:wrap, :string, ->(x) { x })
      result = check('WRAP(x)', x: :numeric, signatures: { wrap: 'numeric -> numeric' })
      expect(result).to be_ok
      expect(result.rendered_type).to eq('numeric')
    end

    it 'checks arity' do
      expect { check('ABS(1, 2)') }.to raise_error(Dentaku::ParseError, /too many operands/)
    end
  end

  describe 'result serialization' do
    it 'exposes a hash summary' do
      result = check('1 + "x"')
      hash = result.to_h
      expect(hash[:ok]).to eq(false)
      expect(hash[:conflicts].first).to include('numeric', 'string')
    end
  end
end
