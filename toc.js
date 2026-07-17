// Populate the sidebar
//
// This is a script, and not included directly in the page, to control the total size of the book.
// The TOC contains an entry for each page, so if each page includes a copy of the TOC,
// the total size of the page becomes O(n**2).
class MDBookSidebarScrollbox extends HTMLElement {
    constructor() {
        super();
    }
    connectedCallback() {
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded "><a href="introduction.html"><strong aria-hidden="true">1.</strong> Introduction</a></li><li class="chapter-item expanded "><a href="examples.html"><strong aria-hidden="true">2.</strong> Examples</a></li><li class="chapter-item expanded affix "><li class="part-title">Tutorials</li><li class="chapter-item expanded "><a href="tutorials/http_client/intro.html"><strong aria-hidden="true">3.</strong> HTTP Client: Uptime Monitor</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="tutorials/http_client/chapter1.html"><strong aria-hidden="true">3.1.</strong> Making an HTTP Request with Chronos</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter2.html"><strong aria-hidden="true">3.2.</strong> Session Reuse</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter3.html"><strong aria-hidden="true">3.3.</strong> Making Requests Concurrently</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter4.html"><strong aria-hidden="true">3.4.</strong> Timeouts &amp; Cancellation</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter5.html"><strong aria-hidden="true">3.5.</strong> Smarter Health Check with Streaming</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter6.html"><strong aria-hidden="true">3.6.</strong> Sending Alerts with POST Requests</a></li><li class="chapter-item expanded "><a href="tutorials/http_client/chapter7.html"><strong aria-hidden="true">3.7.</strong> Scaling &amp; Finishing Touches</a></li></ol></li><li class="chapter-item expanded "><a href="tutorials/http_server/intro.html"><strong aria-hidden="true">4.</strong> HTTP Server: Status Dashboard</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="tutorials/http_server/chapter1.html"><strong aria-hidden="true">4.1.</strong> Setting Up a Basic HTTP Server</a></li><li class="chapter-item expanded "><a href="tutorials/http_server/chapter2.html"><strong aria-hidden="true">4.2.</strong> Handling Multiple Routes</a></li><li class="chapter-item expanded "><a href="tutorials/http_server/chapter3.html"><strong aria-hidden="true">4.3.</strong> Handling POST Requests and Processing JSON</a></li><li class="chapter-item expanded "><a href="tutorials/http_server/chapter4.html"><strong aria-hidden="true">4.4.</strong> Logging Requests with Middleware</a></li><li class="chapter-item expanded "><a href="tutorials/http_server/chapter5.html"><strong aria-hidden="true">4.5.</strong> Bonus Track - Performance and Benchmarking</a></li></ol></li><li class="chapter-item expanded "><li class="part-title">User guide</li><li class="chapter-item expanded "><a href="concepts.html"><strong aria-hidden="true">5.</strong> Core concepts</a></li><li class="chapter-item expanded "><a href="async_procs.html"><strong aria-hidden="true">6.</strong> async functions</a></li><li class="chapter-item expanded "><a href="error_handling.html"><strong aria-hidden="true">7.</strong> Errors and exceptions</a></li><li class="chapter-item expanded "><a href="threads.html"><strong aria-hidden="true">8.</strong> Threads</a></li><li class="chapter-item expanded "><a href="tips.html"><strong aria-hidden="true">9.</strong> Tips, tricks and best practices</a></li><li class="chapter-item expanded "><a href="porting.html"><strong aria-hidden="true">10.</strong> Porting code to chronos</a></li><li class="chapter-item expanded "><a href="http_server_middleware.html"><strong aria-hidden="true">11.</strong> HTTP server middleware</a></li><li class="chapter-item expanded affix "><li class="part-title">Developer guide</li><li class="chapter-item expanded "><a href="book.html"><strong aria-hidden="true">12.</strong> Updating this book</a></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString().split("#")[0].split("?")[0];
        if (current_page.endsWith("/")) {
            current_page += "index.html";
        }
        var links = Array.prototype.slice.call(this.querySelectorAll("a"));
        var l = links.length;
        for (var i = 0; i < l; ++i) {
            var link = links[i];
            var href = link.getAttribute("href");
            if (href && !href.startsWith("#") && !/^(?:[a-z+]+:)?\/\//.test(href)) {
                link.href = path_to_root + href;
            }
            // The "index" page is supposed to alias the first chapter in the book.
            if (link.href === current_page || (i === 0 && path_to_root === "" && current_page.endsWith("/index.html"))) {
                link.classList.add("active");
                var parent = link.parentElement;
                if (parent && parent.classList.contains("chapter-item")) {
                    parent.classList.add("expanded");
                }
                while (parent) {
                    if (parent.tagName === "LI" && parent.previousElementSibling) {
                        if (parent.previousElementSibling.classList.contains("chapter-item")) {
                            parent.previousElementSibling.classList.add("expanded");
                        }
                    }
                    parent = parent.parentElement;
                }
            }
        }
        // Track and set sidebar scroll position
        this.addEventListener('click', function(e) {
            if (e.target.tagName === 'A') {
                sessionStorage.setItem('sidebar-scroll', this.scrollTop);
            }
        }, { passive: true });
        var sidebarScrollTop = sessionStorage.getItem('sidebar-scroll');
        sessionStorage.removeItem('sidebar-scroll');
        if (sidebarScrollTop) {
            // preserve sidebar scroll position when navigating via links within sidebar
            this.scrollTop = sidebarScrollTop;
        } else {
            // scroll sidebar to current active section when navigating via "next/previous chapter" buttons
            var activeSection = document.querySelector('#sidebar .active');
            if (activeSection) {
                activeSection.scrollIntoView({ block: 'center' });
            }
        }
        // Toggle buttons
        var sidebarAnchorToggles = document.querySelectorAll('#sidebar a.toggle');
        function toggleSection(ev) {
            ev.currentTarget.parentElement.classList.toggle('expanded');
        }
        Array.from(sidebarAnchorToggles).forEach(function (el) {
            el.addEventListener('click', toggleSection);
        });
    }
}
window.customElements.define("mdbook-sidebar-scrollbox", MDBookSidebarScrollbox);
