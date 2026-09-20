(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const reveal = () => {
    const nodes = document.querySelectorAll("[data-reveal]");
    if (reduceMotion || !("IntersectionObserver" in window)) {
      nodes.forEach((node) => node.classList.add("is-visible"));
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.01, rootMargin: "80px 0px 80px 0px" }
    );

    nodes.forEach((node) => {
      const rect = node.getBoundingClientRect();
      if (rect.top < window.innerHeight && rect.bottom > 0) {
        node.classList.add("is-visible");
      } else {
        observer.observe(node);
      }
    });

    window.setTimeout(() => {
      nodes.forEach((node) => node.classList.add("is-visible"));
    }, 1200);
  };

  const countUp = () => {
    const el = document.querySelector("[data-count]");
    if (!el) return;

    const target = Number(el.dataset.count);
    if (reduceMotion) {
      el.textContent = String(target);
      return;
    }

    const duration = 1100;
    const start = performance.now();

    const tick = (now) => {
      const progress = Math.min((now - start) / duration, 1);
      const eased = 1 - Math.pow(1 - progress, 3);
      el.textContent = String(Math.round(target * eased));
      if (progress < 1) requestAnimationFrame(tick);
    };

    requestAnimationFrame(tick);
  };

  const lightbox = () => {
    const overlay = document.getElementById("lightbox");
    if (!overlay) return;

    const image = overlay.querySelector("img");
    const caption = overlay.querySelector("figcaption");
    const closeBtn = overlay.querySelector(".lightbox-close");
    const triggers = document.querySelectorAll("[data-lightbox]");

    const close = () => {
      overlay.hidden = true;
      document.body.style.overflow = "";
    };

    const open = (src, text, alt) => {
      image.src = src;
      image.alt = alt || text || "";
      caption.textContent = text || "";
      overlay.hidden = false;
      document.body.style.overflow = "hidden";
      closeBtn.focus();
    };

    triggers.forEach((trigger) => {
      trigger.addEventListener("click", () => {
        const img = trigger.querySelector("img");
        open(trigger.dataset.lightbox, trigger.dataset.caption, img ? img.alt : "");
      });
    });

    closeBtn.addEventListener("click", close);
    overlay.addEventListener("click", (event) => {
      if (event.target === overlay) close();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !overlay.hidden) close();
    });
  };

  reveal();
  countUp();
  lightbox();
})();
