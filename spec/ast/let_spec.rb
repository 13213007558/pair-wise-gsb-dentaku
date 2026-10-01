require 'spec_helper'
require 'dentaku/ast/functions/let'
require 'dentaku'

describe Dentaku::AST::Let do
  let(:calculator) { Dentaku::Calculator.new }

  describe 'evaluation' do
    it 'binds a single name for the result expression' do
      expect(calculator.evaluate!('LET(x, 1, x + 1)')).to eq(2)
    end

    it 'lets later bindings reference earlier names' do
      result = calculator.evaluate!('LET(rate, 0.1, tax, price * rate, price + tax)', price: 100)
      expect(result).to eq(110.0)
    end

    it 'evaluates binding values in the enclosing scope' do
      expect(calculator.evaluate!('LET(x, x + 1, x * 2)', x: 1)).to eq(4)
    end

    it 'exposes nested fields of hash values' do
      expect(calculator.evaluate!('LET(p, point, p.x + p.y)', point: { x: 1, y: 2 })).to eq(3)
    end

    it 'nests inside another LET' do
      expect(calculator.evaluate!('LET(x, 2, LET(y, x * 3, x + y))')).to eq(8)
    end

    it 'nests inside MAP' do
      result = calculator.evaluate!(
        'MAP(items, item, LET(tax, item.price * rate, item.price + tax))',
        items: [{ price: 100 }, { price: 200 }], rate: 0.1
      )
      expect(result).to eq([110.0, 220.0])
    end

    it 'nests inside FILTER' do
      result = calculator.evaluate!(
        'FILTER(items, item, LET(p, item.price, p > 10))',
        items: [{ price: 5 }, { price: 50 }]
      )
      expect(result).to eq([{ price: 50 }])
    end

    it 'supports MAP inside LET' do
      result = calculator.evaluate!(
        'LET(total, SUM(MAP(items, item, item.price)), total * rate)',
        items: [{ price: 10 }, { price: 20 }], rate: 2
      )
      expect(result).to eq(60)
    end

    it 'scopes bindings to the LET body' do
      expect { calculator.evaluate!('LET(x, 1, x) + x') }.to raise_error(
        Dentaku::UnboundVariableError, /x/
      )
    end

    it 'shadows an outer variable only inside the LET' do
      expect(calculator.evaluate!('LET(x, 10, x) + x', x: 1)).to eq(11)
    end
  end

  describe 'argument structure' do
    it 'requires an odd number of arguments' do
      expect { calculator.evaluate!('LET(a, 1, b, 2)') }.to raise_error(
        Dentaku::ParseError, /name\/value pairs followed by a result expression, but got 4/
      )
    end

    it 'requires at least one binding and a result' do
      expect { calculator.evaluate!('LET(a, 1)') }.to raise_error(Dentaku::ParseError, /too few operands/)
    end

    it 'requires binding positions to be identifiers' do
      expect { calculator.evaluate!('LET(1, 2, 3)') }.to raise_error(
        Dentaku::ParseError, 'LET() binding #1 must be an identifier'
      )
    end
  end

  describe 'binding name rules' do
    it 'rejects duplicate bindings and reports both positions' do
      expect { calculator.evaluate!('LET(x, 1, y, 2, x, 3, x)') }.to raise_error(
        Dentaku::ParseError, "LET() binding #3 duplicates 'x', first bound at binding #1"
      )
    end

    it 'rejects references to names bound later' do
      expect { calculator.evaluate!('LET(x, y + 1, y, 2, x)') }.to raise_error(
        Dentaku::ParseError, "LET() binding #1 references 'y' before it is bound (binding #2)"
      )
    end

    it 'allows references to names bound earlier' do
      expect(calculator.evaluate!('LET(x, 1, y, x + 1, y)')).to eq(2)
    end

    it 'rejects binding names containing nested field paths' do
      expect { calculator.evaluate!('LET(item.value, 1, item.value)') }.to raise_error(
        Dentaku::ParseError,
        "LET() binding #1 name 'item.value' conflicts with nested field paths; bindings must be simple names"
      )
    end

    it 'rejects bindings that collide with nested field paths in scope' do
      expect {
        calculator.evaluate!('MAP(items, item, LET(item, 5, item))', items: [{ price: 1 }])
      }.to raise_error(Dentaku::BaseError, /binding 'item' conflicts with nested field path 'item.price'/)
    end

    it 'allows shadowing a name that has no nested fields in scope' do
      expect(calculator.evaluate!('MAP(items, item, LET(item, item * 10, item + 1))', items: [1, 2])).to eq([11, 21])
    end
  end

  describe 'case sensitivity' do
    it 'treats names case-insensitively by default' do
      expect(calculator.evaluate!('LET(Tax, 2, TAX * 3)')).to eq(6)
    end

    it 'detects duplicates case-insensitively by default' do
      expect { calculator.evaluate!('LET(x, 1, X, 2, x)') }.to raise_error(
        Dentaku::ParseError, /duplicates 'x'/
      )
    end

    it 'distinguishes case in case-sensitive mode' do
      sensitive = Dentaku::Calculator.new(case_sensitive: true)
      expect(sensitive.evaluate!('LET(X, 1, x, 2, X + x)')).to eq(3)
    end
  end

  describe 'dependencies and identifiers' do
    it 'reports only free variables as dependencies' do
      expect(calculator.dependencies('LET(rate, 0.1, tax, price * rate, price + tax)')).to eq(['price'])
    end

    it 'resolves free variables through stored formulas' do
      calculator.store_formula('rate', 'base_rate * 2')
      expect(calculator.dependencies('LET(tax, price * rate, tax)')).to eq(['price', 'base_rate'])
    end

    it 'subtracts local names inside nested enumerations' do
      expect(calculator.identifiers('LET(x, a, y, MAP(bs, b, b + x), y + c)')).to eq(%w(a bs c))
    end

    it 'never calls functions to analyze dependencies' do
      count = 0
      calculator.add_function(:track, :numeric, ->(x) { count += 1; x })

      expect(calculator.dependencies('LET(x, track(1), x + y)')).to eq(['y'])
      expect(calculator.identifiers('LET(x, track(1), x + y)')).to eq(['y'])
      expect(count).to eq(0)
    end
  end

  describe 'evaluation semantics' do
    it 'evaluates each binding value exactly once per entry' do
      count = 0
      calculator.add_function(:track, :numeric, ->(x) { count += 1; x })

      expect(calculator.evaluate!('LET(x, track(40), x + x + 2)')).to eq(82)
      expect(count).to eq(1)
    end

    it 'evaluates bindings once per entry when nested in MAP' do
      count = 0
      calculator.add_function(:track, :numeric, ->(x) { count += 1; x })

      result = calculator.evaluate!('MAP(items, item, LET(y, track(item), y * 2))', items: [1, 2, 3])
      expect(result).to eq([2, 4, 6])
      expect(count).to eq(3)
    end

    it 'leaves calculator.memory untouched on normal exit' do
      calculator.store(existing: 1)
      before = calculator.memory.dup

      expect(calculator.evaluate!('LET(x, 10, y, x * 2, x + y + existing)')).to eq(31)
      expect(calculator.memory).to eq(before)
    end

    it 'leaves calculator.memory untouched on exceptional exit' do
      calculator.store(existing: 1)
      calculator.add_function(:boom, :numeric, ->(_x) { raise 'kaboom' })
      before = calculator.memory.dup

      expect { calculator.evaluate!('LET(x, boom(1), x + existing)') }.to raise_error(RuntimeError, 'kaboom')
      expect(calculator.memory).to eq(before)
    end
  end
end
