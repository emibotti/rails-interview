module TodoSync
  # The remote state fetched with one GET: every list with its items, indexed by
  # remote id and by (parsed) source_id. Lists without an id can't be addressed
  # later, so they are dropped here with a warning.
  class Snapshot
    attr_reader :lists

    def initialize(remote_lists)
      @lists = remote_lists.select do |list|
        next true if list.external_id.present?

        Rails.logger.warn("[TodoSync] ignoring a remote list without id (name=#{list.name.inspect})")
        false
      end
    end

    def lists_by_external_id
      @lists_by_external_id ||= lists.index_by(&:external_id)
    end

    def items_by_external_id
      @items_by_external_id ||= lists.flat_map(&:items).select(&:external_id).index_by(&:external_id)
    end

    # Only records created by us have a parseable source_id: { 5 => remote_list }.
    def lists_by_source_id
      @lists_by_source_id ||= index_by_source(lists, :list)
    end

    def items_by_source_id
      @items_by_source_id ||= index_by_source(lists.flat_map(&:items), :item)
    end

    private

    def index_by_source(records, kind)
      records.each_with_object({}) do |record, index|
        parsed_kind, id = ExternalTodo::SourceId.parse(record.source_id)
        index[id] = record if parsed_kind == kind
      end
    end
  end
end
