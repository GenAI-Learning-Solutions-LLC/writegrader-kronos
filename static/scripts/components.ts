class NavBar extends HTMLElement {
    constructor() {
        super();
        this.innerHTML = `
            <nav>
                <a class="btn" href="https://github.com/AndrewGossage/Zoi" target="_blank" style="margin-left: auto;">Source Code</a> 
            </nav>

        `;
    }
}

customElements.define("nav-bar", NavBar);
