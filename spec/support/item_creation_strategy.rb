# Sets config.x.external_todo.item_creation_strategy for one example (or group): `item_creation_strategy 'skip'`.
module ItemCreationStrategyHelper
  def item_creation_strategy(name)
    around do |example|
      config = Rails.configuration.x.external_todo
      original = config.item_creation_strategy
      config.item_creation_strategy = name
      example.run
    ensure
      config.item_creation_strategy = original
    end
  end
end

RSpec.configure { |config| config.extend ItemCreationStrategyHelper }
