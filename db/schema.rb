# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_10_21_230003) do
  create_table "sync_runs", force: :cascade do |t|
    t.string "trigger"
    t.string "status", default: "running", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.json "stats", default: {}, null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sync_states", force: :cascade do |t|
    t.datetime "scheduled_at"
    t.datetime "lock_heartbeat_at"
    t.datetime "last_succeeded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sync_tombstones", force: :cascade do |t|
    t.string "record_type", null: false
    t.string "external_id", null: false
    t.string "list_external_id"
    t.datetime "remote_updated_at"
    t.integer "attempts", default: 0, null: false
    t.datetime "next_attempt_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "external_id"], name: "index_sync_tombstones_on_record_type_and_external_id", unique: true
  end

  create_table "todo_items", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "completed", default: false, null: false
    t.integer "todo_list_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "external_id"
    t.integer "local_version", default: 1, null: false
    t.integer "synced_version", default: 0, null: false
    t.datetime "remote_updated_at"
    t.index ["external_id"], name: "index_todo_items_on_external_id", unique: true
    t.index ["id"], name: "index_todo_items_on_dirty", where: "local_version > synced_version"
    t.index ["todo_list_id", "completed"], name: "index_todo_items_on_todo_list_id_and_completed"
    t.index ["todo_list_id"], name: "index_todo_items_on_todo_list_id"
  end

  create_table "todo_lists", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "mark_all_heartbeat_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "external_id"
    t.integer "local_version", default: 1, null: false
    t.integer "synced_version", default: 0, null: false
    t.datetime "remote_updated_at"
    t.index ["external_id"], name: "index_todo_lists_on_external_id", unique: true
    t.index ["id"], name: "index_todo_lists_on_dirty", where: "local_version > synced_version"
  end

  add_foreign_key "todo_items", "todo_lists"
end
