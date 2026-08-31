const chapters = [...document.querySelectorAll("[data-chapter]")];
const routes = [...document.querySelectorAll("[data-route]")];
const validRoutes = new Set(chapters.map((chapter) => chapter.dataset.chapter));
const toast = document.querySelector("#toast");
let toastTimer;

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("visible"), 1800);
}

function currentRoute() {
  const candidate = window.location.hash.slice(1);
  return validRoutes.has(candidate) ? candidate : "map";
}

function renderRoute({ focus = false } = {}) {
  const route = currentRoute();
  chapters.forEach((chapter) => {
    chapter.hidden = chapter.dataset.chapter !== route;
  });
  routes.forEach((link) => {
    const active = link.dataset.route === route;
    link.classList.toggle("active", active);
    if (active) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  document.title = `${document.querySelector(`[data-chapter="${route}"] h2`).textContent} · Rakazo Fork Field Guide`;
  if (focus) {
    window.scrollTo({ top: 0, behavior: "smooth" });
    document.querySelector("#guide-content").focus({ preventScroll: true });
  }
}

window.addEventListener("hashchange", () => renderRoute({ focus: true }));
if (!window.location.hash || !validRoutes.has(window.location.hash.slice(1))) {
  window.history.replaceState(null, "", "#map");
}
renderRoute();

document.querySelector("#show-release").addEventListener("change", (event) => {
  document.querySelector("#system-map").classList.toggle("show-release", event.target.checked);
});

async function copyText(text) {
  if (navigator.clipboard?.writeText && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const input = document.createElement("textarea");
  input.value = text;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.appendChild(input);
  input.select();
  const copied = document.execCommand("copy");
  input.remove();
  if (!copied) throw new Error("Copy was blocked");
}

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const code = button.closest(".command-block").querySelector("code").textContent.trim();
    try {
      await copyText(code);
      button.textContent = "Copied";
      showToast("Command copied");
      setTimeout(() => {
        button.textContent = "Copy";
      }, 1600);
    } catch {
      showToast("Copy blocked — select the command manually");
    }
  });
});

const checklistKey = "rakazo-fork-guide-checklist-v1";

function readChecklist() {
  try {
    return JSON.parse(localStorage.getItem(checklistKey) || "{}");
  } catch {
    return {};
  }
}

function writeChecklist(value) {
  try {
    localStorage.setItem(checklistKey, JSON.stringify(value));
  } catch {
    // The guide remains usable when a browser blocks local storage on file URLs.
  }
}

const savedChecklist = readChecklist();
document.querySelectorAll("[data-check]").forEach((checkbox) => {
  checkbox.checked = Boolean(savedChecklist[checkbox.dataset.check]);
  checkbox.addEventListener("change", () => {
    const state = readChecklist();
    state[checkbox.dataset.check] = checkbox.checked;
    writeChecklist(state);
  });
});

document.querySelector("#reset-checklist").addEventListener("click", () => {
  document.querySelectorAll("[data-check]").forEach((checkbox) => {
    checkbox.checked = false;
  });
  writeChecklist({});
  showToast("Checklist reset");
});

const scenarioButtons = [...document.querySelectorAll("[data-scenario]")];
const recoveryPanels = [...document.querySelectorAll("[data-recovery]")];
scenarioButtons.forEach((button) => {
  button.addEventListener("click", () => {
    scenarioButtons.forEach((candidate) => {
      const active = candidate === button;
      candidate.classList.toggle("active", active);
      candidate.setAttribute("aria-pressed", String(active));
    });
    recoveryPanels.forEach((panel) => {
      panel.hidden = panel.dataset.recovery !== button.dataset.scenario;
    });
  });
});
