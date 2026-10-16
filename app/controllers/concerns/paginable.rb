# Offset pagination for JSON index endpoints. The response body stays a plain
# array (so existing clients keep working) and the pagination metadata is sent
# in headers: X-Total-Count, X-Total-Pages, X-Page, X-Per-Page and Link.
module Paginable
  extend ActiveSupport::Concern

  PER_PAGE = 25

  private

  # Missing, non numeric or < 1 pages fall back to the first page; pages beyond
  # the last one return an empty collection.
  def paginate(scope)
    total = scope.count
    total_pages = [(total.to_f / PER_PAGE).ceil, 1].max
    page = [params[:page].to_i, 1].max

    set_pagination_headers(page: page, total: total, total_pages: total_pages)

    scope.limit(PER_PAGE).offset((page - 1) * PER_PAGE)
  end

  def set_pagination_headers(page:, total:, total_pages:)
    response.set_header('X-Total-Count', total.to_s)
    response.set_header('X-Total-Pages', total_pages.to_s)
    response.set_header('X-Page', page.to_s)
    response.set_header('X-Per-Page', PER_PAGE.to_s)

    links = { first: 1, last: total_pages }
    links[:prev] = [page - 1, total_pages].min if page > 1
    links[:next] = page + 1 if page < total_pages
    response.set_header('Link', links.map { |rel, number| %(<#{page_url(number)}>; rel="#{rel}") }.join(', '))
  end

  def page_url(number)
    "#{request.base_url}#{request.path}?#{request.query_parameters.merge('page' => number).to_query}"
  end
end
