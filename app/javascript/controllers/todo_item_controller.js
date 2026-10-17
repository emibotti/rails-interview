import { Controller } from "@hotwired/stimulus"

// Optimistic checkbox: the UI changes right away and the change is persisted
// in the background. If the server rejects it, the checkbox goes back to the
// last value the server confirmed.
export default class extends Controller {
  static targets = ["checkbox"]
  static values = { url: String }

  connect() {
    this.confirmed = this.checkboxTarget.checked
    this.pending = 0
    // Requests are sent one at a time, so the last click is the last write.
    this.queue = Promise.resolve()
  }

  toggle() {
    const completed = this.checkboxTarget.checked

    this.show(completed)
    this.pending++
    this.queue = this.queue.then(() => this.persist(completed))
  }

  async persist(completed) {
    let saved = false

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        body: JSON.stringify({ completed })
      })

      saved = response.ok
    } catch (error) {
      saved = false
    }

    this.pending--
    if (saved) this.confirmed = completed

    // Only roll back when no newer click is waiting: that one decides.
    if (!saved && this.pending === 0 && this.checkboxTarget.checked !== this.confirmed) {
      this.checkboxTarget.checked = this.confirmed
      this.show(this.confirmed)
    }
  }

  show(completed) {
    const wasCompleted = this.element.dataset.completed === "true"

    this.element.dataset.completed = completed
    if (wasCompleted !== completed) this.dispatch("toggled", { detail: { delta: completed ? -1 : 1 } })
  }
}
