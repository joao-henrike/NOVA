"use strict";

const backendStatus = document.querySelector("#backend");

if (backendStatus instanceof HTMLElement) {
  fetch("/api/health", {
    headers: { Accept: "application/json" },
  })
    .then(async (response) => {
      if (!response.ok) {
        throw new Error("Backend health check failed.");
      }
      return response.json();
    })
    .then((data) => {
      const status =
        data && typeof data.status === "string" ? data.status : "unknown";
      backendStatus.textContent = `Backend: ${status}`;
    })
    .catch(() => {
      backendStatus.textContent = "Backend: unavailable";
    });
}
