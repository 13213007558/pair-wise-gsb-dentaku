require 'spec_helper'
require 'dentaku'

describe Dentaku::TypeChecker do
  def check(expression, **options)
    described_class.new(**options).check(expression)
  end

  describe 'primitive and literal types' do
    it 'checks numeric expressions' do
      result = check('1 + 2 * 3')
      expect(result).to be_ok
      expect(result.type_spec).to eq(:numeric)
    end

    it 'checks string expressions' do
      expect(check('CONCAT("a", "b")').type_spec).to eq(:string)
    end

    it 'checks logical expressions' do
      expect(check('1 < 2 AND true').type_spec).to eq(:logical)
    end

    it 'checks date arithmetic' do
      variables = { 'day' => :datetime, 'n' => :numeric }
      expect(check('day + n', variables: variables).type_spec).to eq(:datetime)
      expect(check('day - day', variables: variables).type_spec).to eq(:numeric)
    end

    it 'checks array literals with dimensions' do
      expect(check('{1, 2, 3}').type_spec).to eq([:array, :numeric, 3])
      expect(check('{"a", "b"}').type_spec).to eq([:array, :string, 2])
    end

    it 'rejects array literals with mixed element types' do
      result = check('{1, "a"}')
      expect(result).not_to be_ok
      expect(result.conflict.constraints.first.description).to match(/common type/)
    end
  end

  describe 'variable declarations' do
    it 'uses declared types' do
      result = check('price * quantity', variables: { 'price' => :numeric, 'quantity' => :numeric })
      expect(result.type_spec).to eq(:numeric)
    end

    it 'infers types of undeclared variables from usage' do
      result = check('x + 1')
      expect(result).to be_ok
      expect(result.variables).to eq('x' => :numeric)
    end

    it 'reports a conflict between a declaration and usage' do
      result = check('name * 2', variables: { 'name' => :string })
      expect(result).not_to be_ok
      descriptions = result.conflict.constraints.map(&:description)
      expect(descriptions).to include('`name` is declared as string')
      expect(descriptions).to include(match(/left operand of `name \* 2` must be numeric/))
    end
  end

  describe 'function signatures' do
    let(:signatures) do
      { 'double' => { params: [:numeric], returns: :numeric } }
    end

    it 'checks calls against declared signatures' do
      result = check('double(2) + 1', functions: signatures)
      expect(result.type_spec).to eq(:numeric)
    end

    it 'rejects arguments that violate the signature' do
      result = check('double("x")', functions: signatures)
      expect(result).not_to be_ok
      expect(result.conflict.constraints.first.description).to match(/argument 1 of `DOUBLE/)
    end

    it 'rejects wrong argument counts' do
      result = check('double(1, 2)', functions: signatures)
      expect(result).not_to be_ok
      expect(result.conflict.message).to match(/wrong number of arguments/)
    end

    it 'makes declared-but-unregistered functions parseable' do
      result = check('brand_new_fn(1) + 2', functions: { 'brand_new_fn' => { params: [:numeric], returns: :numeric } })
      expect(result).to be_ok
      expect(result.type_spec).to eq(:numeric)
    end
  end

  describe 'IF' do
    it 'finds the common type of both branches' do
      expect(check('IF(true, 1, 2)', variables: {}).type_spec).to eq(:numeric)
    end

    it 'requires the condition to be logical' do
      result = check('IF("x", 1, 2)')
      expect(result).not_to be_ok
      expect(result.conflict.constraints.first.description).to match(/condition.*must be logical/)
    end

    it 'rejects branches without a common type and points at both branches' do
      result = check('IF(true, 1, "x")')
      expect(result).not_to be_ok
      constraint = result.conflict.constraints.first
      expect(constraint.description).to match(/both branches.*common type/)
      expect(constraint.positions.length).to eq(3)
    end
  end

  describe 'CASE and SWITCH' do
    it 'finds the common type of all CASE branches' do
      result = check('CASE x WHEN 1 THEN "one" WHEN 2 THEN "two" ELSE "other" END')
      expect(result).to be_ok
      expect(result.type_spec).to eq(:string)
    end

    it 'rejects CASE branches without a common type' do
      result = check('CASE x WHEN 1 THEN "one" ELSE 2 END')
      expect(result).not_to be_ok
    end

    it 'checks SWITCH results for a common type' do
      expect(check('SWITCH(x, 1, "one", "other")').type_spec).to eq(:string)
      expect(check('SWITCH(x, 1, "one", 2)')).not_to be_ok
    end
  end

  describe 'array dimensions' do
    it 'keeps the dimension through MAP' do
      result = check('MAP(xs, x, x * 2)', variables: { 'xs' => [:array, :numeric, 3] })
      expect(result.type_spec).to eq([:array, :numeric, 3])
    end

    it 'cannot promise a dimension after FILTER' do
      result = check('FILTER(xs, x, x > 1)', variables: { 'xs' => [:array, :numeric, 3] })
      expect(result.type_spec).to eq([:array, :numeric])
    end

    it 'requires INTERCEPT arguments to have equal dimensions' do
      expect(check('INTERCEPT({1, 2, 3}, {4, 5, 6})').type_spec).to eq(:numeric)

      result = check('INTERCEPT({1, 2, 3}, {4, 5})')
      expect(result).not_to be_ok
      expect(result.conflict.message).to match(/dimension mismatch/)
      expect(result.conflict.constraints.length).to be >= 2
    end

    it 'types array element access' do
      result = check('tags[1]', variables: { 'tags' => [:array, :string] })
      expect(result.type_spec).to eq(:string)
    end
  end

  describe 'collection functions' do
    it 'checks the loop expression against the element type' do
      result = check('MAP(xs, x, x + 1)', variables: { 'xs' => [:array, :numeric] })
      expect(result.type_spec).to eq([:array, :numeric])

      conflict = check('MAP(xs, x, x + 1)', variables: { 'xs' => [:array, :string] })
      expect(conflict).not_to be_ok
    end

    it 'requires a logical expression for FILTER, ALL and ANY' do
      variables = { 'xs' => [:array, :numeric] }
      expect(check('FILTER(xs, x, x > 0)', variables: variables)).to be_ok
      expect(check('ALL(xs, x, x > 0)', variables: variables).type_spec).to eq(:logical)
      expect(check('FILTER(xs, x, x + 1)', variables: variables)).not_to be_ok
    end

    it 'checks REDUCE against the accumulator type' do
      result = check('REDUCE(xs, sum, x, sum + x, 0)', variables: { 'xs' => [:array, :numeric] })
      expect(result.type_spec).to eq(:numeric)
    end

    it 'checks aggregates over arrays and scalars' do
      expect(check('SUM(xs)', variables: { 'xs' => [:array, :numeric] }).type_spec).to eq(:numeric)
      expect(check('SUM(1, 2, 3)').type_spec).to eq(:numeric)
      expect(check('SUM(names)', variables: { 'names' => [:array, :string] })).not_to be_ok
    end
  end

  describe 'built-in functions' do
    it 'checks string functions' do
      expect(check('LEFT(name, 2)', variables: { 'name' => :string }).type_spec).to eq(:string)
      expect(check('LEN(name)', variables: { 'name' => :string }).type_spec).to eq(:numeric)
      expect(check('LEFT(name, "x")', variables: { 'name' => :string })).not_to be_ok
    end

    it 'checks math functions' do
      expect(check('SQRT(x)', variables: { 'x' => :numeric }).type_spec).to eq(:numeric)
      expect(check('SQRT(name)', variables: { 'name' => :string })).not_to be_ok
    end

    it 'checks DURATION' do
      expect(check('DURATION(3, "days")').type_spec).to eq(:duration)
    end
  end
  describe 'polymorphic functions' do
    let(:calculator) do
      Dentaku::Calculator.new.tap do |calc|
        calc.add_function('first_of', :any, ->(arr) { arr.first })
      end
    end

    let(:checker) do
      described_class.new(
        variables: { 'names' => [:array, :string], 'scores' => [:array, :numeric] },
        functions: {
          'first_of' => { params: [[:array, :a]], returns: :a },
          'shout' => { params: [:string], returns: :string }
        },
        calculator: calculator
      )
    end

    it 'instantiates type variables per call, never across calls' do
      # first_of(names) is a string, first_of(scores) is a numeric; if the
      # type variable leaked between the two calls, one of them would have
      # to unify string with numeric and this formula could not check
      result = checker.check('IF(first_of(scores) > 0, first_of(names), "none")')
      expect(result).to be_ok
      expect(result.type_spec).to eq(:string)
    end

    it 'still gives each call a concrete, distinct type' do
      expect(checker.check('shout(first_of(names))').type_spec).to eq(:string)
      expect(checker.check('first_of(scores) * 2').type_spec).to eq(:numeric)

      # and using one where the other belongs is a conflict
      expect(checker.check('shout(first_of(scores))')).not_to be_ok
      expect(checker.check('first_of(names) * 2')).not_to be_ok
    end

    it 'keeps built-in polymorphism isolated per call as well' do
      result = check('MIN(names) + MIN(scores)',
                     variables: { 'names' => [:array, :string], 'scores' => [:array, :numeric] })
      expect(result).not_to be_ok # string + numeric
      expect(check('MIN(scores) + 1', variables: { 'scores' => [:array, :numeric] }).type_spec).to eq(:numeric)
    end
  end

  describe 'custom functions without signatures' do
    let(:calculator) do
      Dentaku::Calculator.new.tap do |calc|
        calc.add_function('mystery', :numeric, ->(x) { raise 'must not be executed' })
      end
    end

    it 'leaves the result unknown instead of executing the function' do
      result = described_class.new(calculator: calculator).check('mystery(a) + 1')
      expect(result).to be_ok
      expect(result).to be_unknown
      expect(result.type_spec).to eq(:unknown)
    end

    it 'explains the impact scope of the unknown' do
      result = described_class.new(calculator: calculator).check('CONCAT(mystery(a), "!")')
      expect(result.unknowns.length).to eq(1)

      note = result.unknowns.first
      expect(note.function_name).to eq('mystery')
      expect(note.message).to match(/no declared signature/)
      expect(note.message).to match(/never executed/)
      expect(note.impact).to eq(['argument 1 of `CONCAT(MYSTERY(a), "!")`', 'the whole expression'])
    end

    it 'propagates unknown through IF branches without conflicting' do
      result = described_class.new(calculator: calculator).check('IF(a > 1, mystery(b), 2)')
      expect(result).to be_ok
      expect(result).to be_unknown
    end

    it 'does not guess types even when the function has a legacy return type' do
      # mystery was registered with return type :numeric, but without a
      # static signature the checker stays conservative
      result = described_class.new(calculator: calculator).check('mystery(1)')
      expect(result).to be_unknown
    end
  end

  describe 'connecting formulas' do
    it 'feeds each formula\'s result type into the following formulas' do
      results = described_class.new(variables: { 'price' => :numeric }).check_all(
        'total' => 'price * 2',
        'label' => 'CONCAT(total, " units")'
      )
      expect(results['total'].type_spec).to eq(:numeric)
      expect(results['label'].type_spec).to eq(:string)
    end

    it 'surfaces conflicts that only appear once formulas are connected' do
      checker = described_class.new

      # each formula is fine on its own...
      expect(checker.check('IF(vip, "welcome", "hello")')).to be_ok
      expect(described_class.new.check('greeting * 2')).to be_ok

      # ...but connecting them exposes the conflict
      results = checker.check_all(
        'greeting' => 'IF(vip, "welcome", "hello")',
        'discount' => 'greeting * 2'
      )
      expect(results['greeting']).to be_ok
      expect(results['discount']).not_to be_ok

      conflict = results['discount'].conflict
      formulas = conflict.constraints.map(&:formula)
      expect(formulas).to include('greeting')
      expect(formulas).to include('discount')
    end

    it 'marks downstream types unknown when a formula has a conflict' do
      results = described_class.new.check_all(
        'broken' => 'IF(true, 1, "a")',
        'downstream' => 'broken + 1'
      )
      expect(results['broken']).not_to be_ok
      expect(results['downstream']).to be_ok
      expect(results['downstream']).to be_unknown
      expect(results['downstream'].unknowns.map(&:reason)).to include(:unresolved_formula)
    end
  end

  describe 'error positions' do
    it 'points at the operation in the source expression' do
      result = check('name * 2', variables: { 'name' => :string })
      expect(result.conflict.position).to eq(5) # the `*`
    end

    it 'points at the function call for argument conflicts' do
      result = check('x + double(name)',
                     variables: { 'x' => :numeric, 'name' => :string },
                     functions: { 'double' => { params: [:numeric], returns: :numeric } })
      expect(result.conflict.position).to eq(4) # double
      constraint = result.conflict.constraints.find { |c| c.description.include?('argument 1') }
      expect(constraint).not_to be_nil
      expect(constraint.source).to eq('DOUBLE(name)')
    end

    it 'points at the operand declaration site in the constraint set' do
      result = check('name * 2', variables: { 'name' => :string })
      declaration = result.conflict.constraints.find { |c| c.description.include?('declared') }
      operation = result.conflict.constraints.find { |c| c.description.include?('operand') }
      expect(declaration.position).to be_nil
      expect(operation.position).to eq(5)
    end
  end

  describe Dentaku::Calculator do
    let(:calculator) { Dentaku::Calculator.new }

    it 'checks types through the calculator' do
      result = calculator.check_types('price * 2', variables: { 'price' => :numeric })
      expect(result.type_spec).to eq(:numeric)
    end

    it 'checks connected formulas through the calculator' do
      results = calculator.check_all_types(
        'a' => '1 + 1',
        'b' => 'a * 2'
      )
      expect(results['b'].type_spec).to eq(:numeric)
    end

    it 'knows functions registered on the calculator' do
      calculator.add_function('triple', :numeric, ->(x) { x * 3 })
      result = calculator.check_types('triple(2) + 1',
                                      functions: { 'triple' => { params: [:numeric], returns: :numeric } })
      expect(result.type_spec).to eq(:numeric)
    end
  end
end
