require 'spec_helper'
require 'dentaku'

describe Dentaku::TypeChecker::Type do
  it 'parses scalars and aliases' do
    expect(described_class.parse('numeric').name).to eq(:numeric)
    expect(described_class.parse('bool').name).to eq(:logical)
    expect(described_class.parse('boolean').name).to eq(:logical)
    expect(described_class.parse('text').name).to eq(:string)
  end

  it 'parses nested arrays' do
    type = described_class.parse('array(array(logical))')
    expect(type).to be_a(described_class::ArrayT)
    expect(type.element.element.name).to eq(:logical)
  end

  it 'parses type variables' do
    type = described_class.parse('T')
    expect(type).to be_a(described_class::Var)
    expect(type.label).to eq(:T)
  end

  it 'rejects unknown scalar names' do
    expect { described_class.parse('widget') }.to raise_error(TypeError)
  end
end

describe Dentaku::TypeChecker::Signature do
  it 'parses params and result' do
    signature = described_class.parse('numeric, string -> logical')
    expect(signature.params.map { |t| t.name }).to eq(%i[numeric string])
    expect(signature.result.name).to eq(:logical)
    expect(signature).not_to be_variadic
  end

  it 'parses polymorphic signatures' do
    signature = described_class.parse('array(T) -> T')
    expect(signature.labels).to eq([:T])
  end

  it 'supports variadic params' do
    signature = described_class.parse('logical, logical* -> logical')
    expect(signature).to be_variadic
  end

  it 'supports optional params marked with ?' do
    signature = described_class.parse('numeric, numeric? -> numeric')
    expect(signature.optional_count).to eq(1)
  end

  it 'requires an arrow' do
    expect { described_class.parse('numeric') }.to raise_error(TypeError)
  end

  it 'instantiates fresh variables per call' do
    signature = described_class.parse('array(T) -> T')
    serial = Dentaku::TypeChecker::Checker::Serial.new
    first_params, first_result = signature.instantiate(serial)
    second_params, second_result = signature.instantiate(serial)
    expect(first_params.first.element).to eq(first_result)
    expect(second_params.first.element).to eq(second_result)
    expect(first_result).not_to eq(second_result)
  end
end

describe 'source positions' do
  let(:tokenizer) { Dentaku::Tokenizer.new }

  it 'tags tokens with original offsets' do
    tokens = tokenizer.tokenize('foo + 2.5')
    expect(tokens.map(&:position)).to eq([[0, 3], [4, 5], [6, 9]])
  end

  it 'keeps offsets stable across comments' do
    tokens = tokenizer.tokenize('1 + /* xyz */ 2')
    expect(tokens.last.position).to eq([14, 15])
  end

  it 'tags function call argument spans on the parsed AST' do
    calculator = Dentaku::Calculator.new
    node = calculator.ast('abs(1) + xyz')
    expect(node.source_range).to eq([0, 12])
    expect(node.left.args.first.source_range).to eq([4, 5])
  end
end
