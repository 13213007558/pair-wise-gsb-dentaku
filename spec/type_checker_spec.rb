require 'spec_helper'
require 'dentaku'

describe Dentaku::TypeChecker do
  def check(expression, **options)
    described_class.check(expression, **options)
  end

  def snippets(result, expression)
    result.issues.map { |issue| issue.snippet(expression) }
  end

  describe 'entry points' do
    it 'is exposed on the calculator' do
      result = Dentaku::Calculator.new.check('a + 1', types: { a: :numeric })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
    end

    it 'is exposed on the Dentaku module' do
      expect(Dentaku.check('a + 1', types: { a: :numeric })).to be_ok
    end

    it 'accepts a pre-parsed AST' do
      ast = Dentaku::Calculator.new.ast('a + 1')
      expect(check(ast, types: { a: :numeric })).to be_ok
    end

    it 'sees custom functions registered on the calculator' do
      calculator = Dentaku::Calculator.new
      calculator.add_function('triple', :numeric, ->(x) { x * 3 })
      result = calculator.check('triple(price)', types: { price: :numeric })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
    end
  end

  describe 'type inference' do
    it 'infers literal types' do
      expect(check('1 + 2').type.to_s).to eq('numeric')
      expect(check('"a"').type.to_s).to eq('string')
      expect(check('true').type.to_s).to eq('logical')
      expect(check('null').type.to_s).to eq('nil')
    end

    it 'infers declared variable types' do
      result = check('CONCAT(name, "!")', types: { name: :string })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('string')
    end

    it 'matches declared names case-insensitively by default' do
      expect(check('AGE + 1', types: { age: :numeric })).to be_ok
    end

    it 'infers datetime arithmetic' do
      types = { start_date: :datetime, end_date: :datetime }
      expect(check('start_date + 30', types: types).type.to_s).to eq('datetime')
      expect(check('end_date - start_date', types: types).type.to_s).to eq('numeric')
      expect(check('start_date + DURATION(3, days)', types: types).type.to_s).to eq('datetime')
    end

    it 'infers array types from literals and declarations' do
      expect(check('{1, 2, 3}').type.to_s).to eq('array<numeric>')
      expect(check('{1, "a"}').type.to_s).to eq('array<numeric | string>')
      expect(check('{}').type.to_s).to eq('array<unknown>')
      expect(check('nums', types: { nums: [:array, :numeric] }).type.to_s).to eq('array<numeric>')
    end

    it 'infers numeric for the numeric operators' do
      types = { a: :numeric, b: :numeric }
      expect(check('a * b', types: types).type.to_s).to eq('numeric')
      expect(check('a / b', types: types).type.to_s).to eq('numeric')
      expect(check('a % b', types: types).type.to_s).to eq('numeric')
      expect(check('a ^ b', types: types).type.to_s).to eq('numeric')
      expect(check('a | b', types: types).type.to_s).to eq('numeric')
      expect(check('-a', types: types).type.to_s).to eq('numeric')
      expect(check('a %', types: types).type.to_s).to eq('numeric')
    end
  end

  describe 'definite type conflicts' do
    it 'catches date plus string, pointing at the operand' do
      expression = 'start_date + name'
      result = check(expression, types: { start_date: :datetime, name: :string })
      expect(result).not_to be_ok
      expect(result.issues.length).to eq(1)

      issue = result.issues.first
      expect(issue.message).to include('right operand of +')
      expect(issue.message).to include('got string')
      expect(issue.snippet(expression)).to eq('name')
      expect(issue.offset).to eq(expression.index('name'))
      expect(issue.length).to eq(4)
    end

    it 'rejects datetime + datetime' do
      result = check('a + b', types: { a: :datetime, b: :datetime })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('not supported')
    end

    it 'rejects non-numeric multiplication' do
      result = check('price * name', types: { price: :numeric, name: :string })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('right operand of *')
    end

    it 'rejects non-logical combinator operands' do
      result = check('flag AND count', types: { flag: :logical, count: :numeric })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('right operand of and')
    end

    it 'rejects non-logical IF conditions' do
      expression = 'IF(count, 1, 2)'
      result = check(expression, types: { count: :numeric })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['count'])
    end

    it 'rejects incomparable comparisons' do
      result = check('name < 5', types: { name: :string })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('cannot compare string with numeric')
    end

    it 'allows equality between any types' do
      expect(check('name = 5', types: { name: :string })).to be_ok
      expect(check('a != b', types: { a: :datetime, b: :string })).to be_ok
    end

    it 'checks unary minus' do
      expect(check('-name', types: { name: :string })).not_to be_ok
    end

    it 'checks bitwise operands' do
      result = check('a | b', types: { a: :numeric, b: :string })
      expect(result).not_to be_ok
    end
  end

  describe 'union types' do
    it 'unions IF branches with different types' do
      result = check('IF(flag, 1, "a")', types: { flag: :logical })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric | string')
    end

    it 'collapses IF branches with the same type' do
      expect(check('IF(flag, 1, 2)', types: { flag: :logical }).type.to_s).to eq('numeric')
    end

    it 'includes nil branches in unions' do
      result = check('IF(flag, null, 3)', types: { flag: :logical })
      expect(result.type.to_s).to eq('nil | numeric')
    end

    it 'reports union members that are invalid in the surrounding expression' do
      expression = 'IF(flag, total, "n/a") * tax_rate'
      types = { flag: :logical, total: :numeric, tax_rate: :numeric }
      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['IF(flag, total, "n/a")'])
      expect(result.type.to_s).to eq('numeric')
    end

    it 'unions CASE branches' do
      result = check('CASE n WHEN 1 THEN "one" ELSE "other" END', types: { n: :numeric })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('string')
    end

    it 'flags WHEN values that can never match the CASE value' do
      expression = 'CASE name WHEN 1 THEN "one" ELSE "other" END'
      result = check(expression, types: { name: :string })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['1'])
    end

    it 'checks CASE without an ELSE branch' do
      result = check('CASE n WHEN 1 THEN "one" END', types: { n: :numeric })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('string')
    end
  end

  describe 'unknown types' do
    it 'treats undeclared variables as unknown, not illegal' do
      result = check('anything + 1')
      expect(result).to be_ok
      expect(result).to be_unknown
      expect(result.type.to_s).to eq('unknown')
    end

    it 'propagates unknown through function results' do
      result = check('ABS(mystery)')
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
    end

    it 'does not report signature mismatches caused only by unknowns' do
      result = check('discount(mystery)',
                     functions: { discount: [{ params: [:numeric], returns: :numeric }] })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
    end

    it 'marks the empty expression as nil' do
      expect(check('').type.to_s).to eq('nil')
    end
  end

  describe 'custom function signatures' do
    it 'checks calls against declared signatures without calling the function' do
      calls = 0
      calculator = Dentaku::Calculator.new
      calculator.add_function('discount', :numeric, ->(a, b) { calls += 1; a })
      result = calculator.check(
        'discount(price, 2)',
        types: { price: :numeric },
        functions: { discount: [{ params: [:numeric, :numeric], returns: :numeric }] }
      )
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
      expect(calls).to eq(0)
    end

    it 'registers a check-only stub for signature-only functions' do
      result = check('discount(price)',
                     types: { price: :numeric },
                     functions: { discount: [{ params: [:numeric], returns: :numeric }] })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('numeric')
    end

    it 'makes check-only stubs raise when evaluated' do
      checker = described_class.new(functions: { ghost: [{ params: [:numeric], returns: :numeric }] })
      calculator = checker.instance_variable_get(:@calculator)
      expect { calculator.evaluate!('ghost(1)') }
        .to raise_error(Dentaku::BaseError, /static checking only/)
    end

    it 'reports calls with no matching signature' do
      expression = 'discount(price)'
      result = check(expression,
                     types: { price: :string },
                     functions: { discount: [{ params: [:numeric], returns: :numeric }] })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('no matching signature for discount(string)')
      expect(snippets(result, expression)).to eq(['discount(price)'])
      expect(result.type.to_s).to eq('unknown')
    end

    it 'reports true ambiguity when matching signatures disagree on the result' do
      result = check('flex(1)', functions: {
        flex: [
          { params: [:numeric], returns: :numeric },
          { params: [[:rest, :numeric]], returns: :string }
        ]
      })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('ambiguous call to flex(numeric)')
      expect(result.type.to_s).to eq('numeric | string')
    end

    it 'accepts several signatures when only one matches' do
      functions = {
        flex: [
          { params: [:numeric], returns: :numeric },
          { params: [:string], returns: :string }
        ]
      }
      expect(check('flex(1)', functions: functions).type.to_s).to eq('numeric')
      expect(check('flex("a")', functions: functions).type.to_s).to eq('string')
    end

    it 'is not ambiguous when matching signatures agree on the result' do
      result = check('flex(1)', functions: {
        flex: [
          { params: [:numeric], returns: :string },
          { params: [[:rest, :numeric]], returns: :string }
        ]
      })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('string')
    end

    it 'supports optional and rest parameters' do
      expect(check('ROUND(price)', types: { price: :numeric })).to be_ok
      expect(check('ROUND(price, 2)', types: { price: :numeric })).to be_ok
      expect(check('SUM(1, 2, 3)')).to be_ok
      expect(check('SUM(nums)', types: { nums: [:array, :numeric] })).to be_ok
    end

    it 'checks built-in function signatures' do
      expression = 'SUM(nums, name)'
      result = check(expression, types: { nums: [:array, :numeric], name: :string })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('no matching signature for sum')
    end

    it 'checks logical built-ins' do
      expect(check('AND(a, b)', types: { a: :logical, b: :logical })).to be_ok
      expect(check('NOT(flag)', types: { flag: :logical })).to be_ok
      expect(check('NOT(1)')).not_to be_ok
      expect(check('AND(a, 1)', types: { a: :logical })).not_to be_ok
    end

    it 'checks string built-ins' do
      expect(check('LEFT(name, 2)', types: { name: :string })).to be_ok
      expect(check('CONCAT(name, 1, true)', types: { name: :string })).to be_ok
      expect(check('LEFT(name, 2) + 1', types: { name: :string })).not_to be_ok
    end

    it 'checks math functions' do
      expect(check('SQRT(price)', types: { price: :numeric })).to be_ok
      result = check('SQRT(name)', types: { name: :string })
      expect(result).not_to be_ok
    end

    it 'checks DURATION arguments' do
      result = check('DURATION(name, days)', types: { name: :string })
      expect(result).not_to be_ok
    end

    it 'falls back to the registered return type without declared signatures' do
      calculator = Dentaku::Calculator.new
      calculator.add_function('triple', :numeric, ->(x) { x * 3 })
      expect(calculator.check('triple(anything)').type.to_s).to eq('numeric')
    end

    it 'treats unrecognised registered types as unknown' do
      calculator = Dentaku::Calculator.new
      calculator.add_function('weird', :bogus, ->(x) { x })
      expect(calculator.check('weird(1)').type.to_s).to eq('unknown')
    end

    it 'treats functions without any type information as unknown' do
      calculator = Dentaku::Calculator.new
      klass = Class.new(Dentaku::AST::Function) do
        def self.min_param_count
          0
        end

        def self.max_param_count
          1
        end
      end
      calculator.function_registry.register_class('raw', klass)
      expect(calculator.check('raw(1)').type.to_s).to eq('unknown')
    end

    it 'rejects invalid declarations' do
      expect { check('a', types: { a: :widget }) }.to raise_error(ArgumentError)
      expect { check('a', types: { a: [:widget, 1] }) }.to raise_error(ArgumentError)
      expect { check('f(1)', functions: { f: ['nope'] }) }.to raise_error(ArgumentError)
    end
  end

  describe 'enum functions' do
    it 'binds the element type to the item variable' do
      expression = 'MAP(users, u, u + name)'
      result = check(expression, types: { users: [:array, :numeric], name: :string })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['name'])
    end

    it 'infers MAP result as an array of the body type' do
      result = check('MAP(nums, n, n * 2)', types: { nums: [:array, :numeric] })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('array<numeric>')
    end

    it 'requires a logical FILTER expression' do
      expression = 'FILTER(items, i, i + 1)'
      result = check(expression, types: { items: [:array, :numeric] })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['i + 1'])
    end

    it 'checks ALL and ANY bodies' do
      result = check('ALL(nums, n, n > 0)', types: { nums: [:array, :numeric] })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('logical')
      expect(check('ANY(nums, n, n)', types: { nums: [:array, :numeric] })).not_to be_ok
    end

    it 'checks REDUCE with memo and item bindings' do
      good = check('REDUCE(nums, memo, n, memo + n, 0)', types: { nums: [:array, :numeric] })
      expect(good).to be_ok
      expect(good.type.to_s).to eq('numeric')

      bad = check('REDUCE(nums, memo, n, memo + n, name)',
                  types: { nums: [:array, :numeric], name: :string })
      expect(bad).not_to be_ok
    end

    it 'checks PLUCK collections and defaults' do
      result = check('PLUCK(users, age)', types: { users: :array })
      expect(result).to be_ok
      expect(result.type.to_s).to eq('array<unknown>')
      expect(check('PLUCK(users, age, 0)', types: { users: :array })).to be_ok
      expect(check('PLUCK(price, age)', types: { price: :numeric })).not_to be_ok
    end

    it 'checks nested enum functions' do
      expression = 'MAP(matrix, row, MAP(row, cell, cell + name))'
      types = { matrix: [:array, [:array, :numeric]], name: :string }
      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['name'])
    end

    it 'flags field access on primitive enum items' do
      expression = 'FILTER(items, i, i.price > 10)'
      result = check(expression, types: { items: [:array, :numeric] })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['i.price'])
    end

    it 'allows field access when the item type is unknown' do
      expect(check('MAP(users, u, u.age)', types: { users: :array })).to be_ok
    end

    it 'rejects non-array collections' do
      result = check('MAP(price, p, p * 2)', types: { price: :numeric })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('expected an array')
    end
  end

  describe 'index access' do
    it 'infers the element type of arrays' do
      expect(check('nums[0] + 1', types: { nums: [:array, :numeric] })).to be_ok
    end

    it 'flags element types that do not fit the context' do
      expression = 'names[0] + 1'
      result = check(expression, types: { names: [:array, :string] })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['names[0]'])
    end

    it 'rejects indexing into non-indexable values' do
      result = check('price[0]', types: { price: :numeric })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('cannot index into numeric')
    end

    it 'allows string indexing' do
      expect(check('name[0]', types: { name: :string }).type.to_s).to eq('string')
    end

    it 'rejects non-scalar indexes' do
      result = check('nums[flag]', types: { nums: :array, flag: :logical })
      expect(result).not_to be_ok
      expect(result.issues.first.message).to include('index')
    end
  end

  describe 'source locations' do
    it 'locates issues in the original expression text' do
      expression = 'IF(age >= 18, price * 0.9, start_date + name)'
      types = { age: :numeric, price: :numeric, start_date: :datetime, name: :string }
      result = check(expression, types: types)

      issue = result.issues.first
      expect(issue.offset).to eq(expression.index('name'))
      expect(issue.length).to eq(4)
      expect(expression[issue.loc.to_range]).to eq('name')
    end

    it 'keeps offsets stable across stripped comments' do
      expression = 'start_date /* plus */ + name'
      result = check(expression, types: { start_date: :datetime, name: :string })
      expect(snippets(result, expression)).to eq(['name'])
    end

    it 'maps locations through alias replacement' do
      # spec_helper registers the alias roundupup -> roundup
      expression = 'ROUNDUPUP(name)'
      result = check(expression, types: { name: :string })
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['ROUNDUPUP(name)'])
    end

    it 'reports issues for nodes without source locations' do
      node = Dentaku::AST::Addition.new(
        Dentaku::AST::Identifier.new(Dentaku::Token.new(:identifier, 'a')),
        Dentaku::AST::Identifier.new(Dentaku::Token.new(:identifier, 'b'))
      )
      result = check(node, types: { a: :string, b: :string })
      expect(result).not_to be_ok

      issue = result.issues.first
      expect(issue.loc).to be_nil
      expect(issue.offset).to be_nil
      expect(issue.snippet('a + b')).to be_nil
      expect(issue.to_s).not_to include('(at ')
    end
  end

  describe 'token locations' do
    it 'tracks offsets in the original text' do
      tokens = Dentaku::Tokenizer.new.tokenize('alpha + 22')
      expect(tokens.map { |token| token.loc.to_s }).to eq(['0...5', '6...7', '8...10'])
    end

    it 'preserves offsets when comments are stripped' do
      expression = 'a /* note */ + 2'
      tokens = Dentaku::Tokenizer.new.tokenize(expression)
      expect(tokens.last.loc.offset).to eq(expression.index('2'))
    end
  end

  describe 'regression: lucky runtime values that hide type errors' do
    let(:calculator) { Dentaku::Calculator.new }

    it 'flags an IF branch the current data never takes' do
      expression = 'IF(age >= 18, price * 0.9, start_date + name)'
      types = { age: :numeric, price: :numeric, start_date: :datetime, name: :string }

      lucky = { age: 30, price: 100, start_date: Date.today, name: 'oops' }
      expect(calculator.evaluate(expression, lucky)).to eq(90)

      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['name'])
    end

    it 'flags a union result that breaks the surrounding operation' do
      expression = 'IF(flag, total, "n/a") * tax_rate'
      types = { flag: :logical, total: :numeric, tax_rate: :numeric }

      lucky = { flag: true, total: 100, tax_rate: 2 }
      expect(calculator.evaluate(expression, lucky)).to eq(200)

      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['IF(flag, total, "n/a")'])
      expect(result.issues.first.message).to include('got string')
    end

    it 'flags an enum body that empty collections never evaluate' do
      expression = 'MAP(users, u, u + name)'
      types = { users: [:array, :numeric], name: :string }

      expect(calculator.evaluate(expression, users: [], name: 'x')).to eq([])

      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['name'])
    end

    it 'flags a non-logical FILTER body that empty collections never evaluate' do
      expression = 'FILTER(items, i, i + 1)'
      types = { items: [:array, :numeric] }

      expect(calculator.evaluate(expression, items: [])).to eq([])

      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['i + 1'])
    end

    it 'flags a CASE else branch the current data never takes' do
      expression = 'CASE n WHEN 1 THEN "one" ELSE n + name END'
      types = { n: :numeric, name: :string }

      expect(calculator.evaluate(expression, n: 1, name: 'x')).to eq('one')

      result = check(expression, types: types)
      expect(result).not_to be_ok
      expect(snippets(result, expression)).to eq(['name'])
    end
  end

  describe Dentaku::TypeChecker::Type do
    it 'compares structurally' do
      expect(described_class.from_declaration([:array, :numeric]))
        .to eq(described_class.from_declaration([:array, :numeric]))
      expect(described_class.from_declaration(:numeric))
        .not_to eq(described_class.from_declaration(:string))
    end

    it 'accepts declaration aliases' do
      expect(described_class.from_declaration('integer').to_s).to eq('numeric')
      expect(described_class.from_declaration(:boolean).to_s).to eq('logical')
      expect(described_class.from_declaration(:date).to_s).to eq('datetime')
      expect(described_class.from_declaration(:list).to_s).to eq('array<unknown>')
      expect(described_class.from_declaration(:any).to_s).to eq('unknown')
      expect(described_class.from_declaration([:array]).to_s).to eq('array<unknown>')
      expect(described_class.from_declaration([:union, :numeric, :string]).to_s)
        .to eq('numeric | string')
    end
  end

  describe Dentaku::SourceLocation do
    it 'spans a slice of the source' do
      loc = described_class.new(2, 3)
      expect(loc.offset).to eq(2)
      expect(loc.length).to eq(3)
      expect(loc.end_offset).to eq(5)
      expect(loc.to_range).to eq(2...5)
      expect(loc.snippet('abcdef')).to eq('cde')
      expect(loc.to_s).to eq('2...5')
    end

    it 'is comparable and hashable' do
      a = Dentaku::SourceLocation.new(0, 1)
      b = Dentaku::SourceLocation.new(2, 1)
      expect([b, a].sort).to eq([a, b])
      expect(a).to eq(Dentaku::SourceLocation.new(0, 1))
      expect(a).not_to eq(b)
      expect({ a => 1 }[Dentaku::SourceLocation.new(0, 1)]).to eq(1)
    end
  end
end
