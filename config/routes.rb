Rails.application.routes.draw do
  namespace :api do
    resources :todo_lists, except: %i[new edit], path: :todolists do
      resources :todo_items, except: %i[new edit], path: :todoitems
      # Alias of /todoitems, used by the external Postman collection.
      resources :todo_items, except: %i[new edit], path: :todos, as: :todos
    end
  end

  resources :todo_lists, only: %i[index new show], path: :todolists do
    member { post :complete_all }
    resources :todo_items, only: :update, path: :todoitems
  end
end
