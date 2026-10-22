module TodoSync
  module ItemCreation
    # Does nothing remote: the items stay unlinked and dirty with a sync_error that
    # `todo_sync:status` shows. Idempotent: rows already carrying the error are not rewritten.
    class Skip
      MESSAGE = "unsupported_by_remote: the external API cannot create items in an existing list"

      def self.call(snapshot, run, client:, reason: nil)
        new(run).call(reason)
      end

      def initialize(run)
        @run = run
      end

      def call(reason = nil, only_list_ids: nil)
        message = reason ? "#{MESSAGE} (#{reason})" : MESSAGE
        lists = only_list_ids ? TodoList.where(id: only_list_ids) : ItemCreation.lists_with_unlinked_items

        lists.each do |list|
          pending = TodoItem.unlinked.where(todo_list_id: list.id)
          changed = pending.where(sync_error: nil).or(pending.where.not(sync_error: message)).update_all(sync_error: message)
          next if changed.zero?

          @run.increment_stat(:items_skipped_unsupported, changed)
          Rails.logger.warn("[TodoSync] #{changed} new items of list #{list.id} are not synced: #{message}")
        end
      end
    end
  end
end
