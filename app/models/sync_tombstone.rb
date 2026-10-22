# Remembers a record deleted locally that still exists in the external API, so
# the sync can send the remote DELETE and the pull doesn't bring it back.
class SyncTombstone < ApplicationRecord
  RECORD_TYPES = %w[TodoList TodoItem].freeze

  validates :record_type, inclusion: { in: RECORD_TYPES }
  validates :external_id, presence: true
end
