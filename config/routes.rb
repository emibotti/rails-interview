Rails.application.routes.draw do
  namespace :api do
    resources :todo_lists, except: %i[new edit], path: :todolists do
      resources :todo_items, except: %i[new edit], path: :todoitems
    end
  end

  resources :todo_lists, only: %i[index new], path: :todolists
end
