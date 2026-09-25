import { Controller } from "@hotwired/stimulus"

// R1.9: a dev/sit/uat/prod env name fixes its rank, any other name must
// choose one. As the name is typed, show the fixed rank or the (required,
// unselected) choice -- disabling the hidden select so the browser neither
// submits it nor holds the form on its `required`. Without JS the server
// forces a known rank and refuses an other name with no rank.
export default class extends Controller {
  static targets = ["name", "fixed", "choose", "select"]
  static values = { known: Object, fixedTemplate: String }

  update() {
    const name = this.nameTarget.value.trim().toLowerCase()
    const rank = this.knownValue[name]
    const known = rank !== undefined

    this.fixedTarget.hidden = !known
    this.chooseTarget.hidden = known
    this.selectTarget.disabled = known
    if (known) this.fixedTarget.textContent = this.fixedTemplateValue.replace("%{rank}", rank)
  }
}
