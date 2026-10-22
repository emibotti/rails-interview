class TodoItem < ApplicationRecord
  include Syncable

  belongs_to :todo_list

  validates :name, presence: true

  def self.sync_attributes
    %w[name completed]
  end

  private

  def tombstone_list_external_id
    todo_list.external_id
  end
end
