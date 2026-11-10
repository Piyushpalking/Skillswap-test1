
(() => {
    "use strict";

    const $ = (id) => document.getElementById(id);
    const client = window.supabase.createClient(
        SUPABASE_CONFIG.URL,
        SUPABASE_CONFIG.ANON_KEY
    );

    let currentUser = null;
    let authMode = "signup";

    function toast(message) {
        const el = $("toast");
        el.textContent = message;
        el.classList.add("show");
        setTimeout(() => el.classList.remove("show"), 3000);
    }

    function escapeHTML(value = "") {
        return String(value).replace(/[&<>"']/g, char => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;",
            '"': "&quot;", "'": "&#39;"
        })[char]);
    }

    function showModal(mode = "signup") {
        authMode = mode;
        $("authTitle").textContent =
            mode === "signup" ? "Create your account" : "Welcome back";
        $("authSubmit").textContent =
            mode === "signup" ? "Create account" : "Log in";
        $("authName").classList.toggle("hidden", mode !== "signup");
        $("authSwitch").innerHTML = mode === "signup"
            ? 'Already registered? <button id="switchAuth" class="text-btn">Log in</button>'
            : 'New here? <button id="switchAuth" class="text-btn">Create account</button>';

        $("authModal").classList.remove("hidden");
        $("authMessage").textContent = "";
    }

    function closeModal() {
        $("authModal").classList.add("hidden");
    }

    async function loadProfile() {
        if (!currentUser) return;

        const { data, error } = await client
            .from("profiles")
            .select("*")
            .eq("id", currentUser.id)
            .single();

        if (error) {
            toast("Could not load profile: " + error.message);
            return;
        }

        $("displayName").value = data.display_name || "";
        $("bio").value = data.bio || "";
        $("userEmail").textContent = currentUser.email || "";
    }

    async function updateUI() {
        const loggedIn = !!currentUser;

        $("loginNav").classList.toggle("hidden", loggedIn);
        $("signupNav").classList.toggle("hidden", loggedIn);
        $("logoutBtn").classList.toggle("hidden", !loggedIn);
        $("dashboard").classList.toggle("hidden", !loggedIn);

        if (loggedIn) {
            await loadProfile();
            await loadMatches();
            await loadRequests();
        }
    }

    async function handleAuth(event) {
        event.preventDefault();

        const email = $("authEmail").value.trim();
        const password = $("authPassword").value;
        const name = $("authName").value.trim();

        $("authSubmit").disabled = true;
        $("authMessage").textContent = "Please wait...";

        try {
            let result;

            if (authMode === "signup") {
                result = await client.auth.signUp({
                    email,
                    password,
                    options: {
                        data: { display_name: name || "Member" }
                    }
                });
            } else {
                result = await client.auth.signInWithPassword({
                    email, password
                });
            }

            if (result.error) throw result.error;

            if (authMode === "signup" && !result.data.session) {
                $("authMessage").textContent =
                    "Account created. Check your email to confirm it, then log in.";
                return;
            }

            closeModal();
            toast(authMode === "signup" ? "Welcome to SkillSwap!" : "Logged in!");
        } catch (error) {
            $("authMessage").textContent = error.message;
        } finally {
            $("authSubmit").disabled = false;
        }
    }

    async function saveProfile() {
        const { error } = await client
            .from("profiles")
            .update({
                display_name: $("displayName").value.trim(),
                bio: $("bio").value.trim()
            })
            .eq("id", currentUser.id);

        if (error) return toast(error.message);
        toast("Profile saved!");
    }

    async function addSkill() {
        const name = $("skillName").value.trim();
        if (!name) return toast("Enter a skill name.");

        const { error } = await client.from("skills").insert({
            user_id: currentUser.id,
            name,
            skill_type: $("skillType").value,
            category: $("skillCategory").value
        });

        if (error) return toast(error.message);

        $("skillName").value = "";
        toast("Skill added!");
        await loadSkills();
        await loadMatches();
    }

    async function loadSkills() {
        const search = $("skillSearch").value.trim();
        const category = $("categoryFilter").value;

        let query = client
            .from("skills")
            .select("id,name,category,skill_type,user_id,profiles(display_name,bio)")
            .order("created_at", { ascending: false })
            .limit(60);

        if (search) query = query.ilike("name", `%${search}%`);
        if (category) query = query.eq("category", category);

        const { data, error } = await query;
        if (error) {
            $("skillsGrid").innerHTML =
                `<p class="muted">${escapeHTML(error.message)}</p>`;
            return;
        }

        if (!data.length) {
            $("skillsGrid").innerHTML =
                '<p class="muted">No skills found. Be the first to add one!</p>';
            return;
        }

        $("skillsGrid").innerHTML = data.map(skill => `
            <article class="skill-card">
                <span class="tag">${escapeHTML(skill.category)}</span>
                <span class="tag">${escapeHTML(skill.skill_type)}</span>
                <h3>${escapeHTML(skill.name)}</h3>
                <p>By ${escapeHTML(skill.profiles?.display_name || "Member")}</p>
                <p>${escapeHTML(skill.profiles?.bio || "SkillSwap community member")}</p>
                ${currentUser && skill.user_id !== currentUser.id
                    ? `<button class="btn btn-primary request-skill"
                        data-user="${escapeHTML(skill.user_id)}">
                        Send exchange request
                       </button>`
                    : ""}
            </article>
        `).join("");
    }

    async function loadMatches() {
        const container = $("matchesList");
        container.innerHTML = '<p class="muted">Finding compatible people...</p>';

        const { data, error } = await client.rpc("get_skill_matches");

        if (error) {
            container.innerHTML =
                `<p class="muted">${escapeHTML(error.message)}</p>`;
            return;
        }

        if (!data?.length) {
            container.innerHTML =
                '<p class="muted">Add skills you teach and want to learn to discover matches.</p>';
            return;
        }

        container.innerHTML = data.map(match => `
            <div class="match-item">
                <strong>${escapeHTML(match.display_name)}</strong>
                <span class="tag">${Number(match.score)} compatibility points</span>
                <p>${escapeHTML(match.bio || "")}</p>
                <p>Can teach: ${escapeHTML((match.offers || []).join(", "))}</p>
                <p>Wants to learn: ${escapeHTML((match.wants || []).join(", "))}</p>
                <button class="btn btn-primary request-match"
                    data-user="${escapeHTML(match.user_id)}">
                    Connect
                </button>
            </div>
        `).join("");
    }

    async function sendRequest(receiverId) {
        if (!currentUser) return showModal("login");
        if (receiverId === currentUser.id) return;

        const { error } = await client.from("exchange_requests").insert({
            sender_id: currentUser.id,
            receiver_id: receiverId,
            message: "Hi! I'd like to exchange skills with you."
        });

        if (error) {
            toast(error.code === "23505"
                ? "A request may already exist."
                : error.message);
            return;
        }

        toast("Exchange request sent!");
        await loadRequests();
    }

    async function loadRequests() {
        if (!currentUser) return;

        const { data, error } = await client
            .from("exchange_requests")
            .select("id,sender_id,receiver_id,message,status,created_at")
            .or(`sender_id.eq.${currentUser.id},receiver_id.eq.${currentUser.id}`)
            .order("created_at", { ascending: false });

        if (error) {
            $("requestsList").textContent = error.message;
            return;
        }

        if (!data.length) {
            $("requestsList").innerHTML =
                '<p class="muted">No exchange requests yet.</p>';
            return;
        }

        $("requestsList").innerHTML = data.map(request => {
            const incoming = request.receiver_id === currentUser.id;

            return `
                <div class="request-item">
                    <strong>${incoming ? "Incoming request" : "Sent request"}</strong>
                    <span class="tag">${escapeHTML(request.status)}</span>
                    <p>${escapeHTML(request.message || "")}</p>

                    ${incoming && request.status === "pending" ? `
                        <button class="btn btn-primary accept-request"
                            data-id="${escapeHTML(request.id)}">Accept</button>
                        <button class="btn btn-ghost reject-request"
                            data-id="${escapeHTML(request.id)}">Reject</button>
                    ` : ""}

                    ${request.status === "accepted" ? `
                        <button class="btn btn-ghost open-chat"
                            data-id="${escapeHTML(request.id)}">Open chat</button>
                        <button class="btn btn-ghost schedule-session"
                            data-id="${escapeHTML(request.id)}">Schedule session</button>
                    ` : ""}
                </div>
            `;
        }).join("");
    }

    async function updateRequest(id, status) {
        const { error } = await client
            .from("exchange_requests")
            .update({ status })
            .eq("id", id);

        if (error) return toast(error.message);

        toast("Request " + status + ".");
        await loadRequests();
    }

    async function openChat(requestId) {
        const content = prompt("Type your message:");
        if (!content?.trim()) return;

        const { error } = await client.from("messages").insert({
            request_id: requestId,
            sender_id: currentUser.id,
            content: content.trim()
        });

        if (error) return toast(error.message);
        toast("Message sent!");
    }

    async function scheduleSession(requestId) {
        const value = prompt("Enter date and time (example: 2026-12-01T18:00:00+05:30)");
        if (!value) return;

        const date = new Date(value);
        if (Number.isNaN(date.getTime()) || date <= new Date()) {
            return toast("Enter a valid future date and time.");
        }

        const { error } = await client.from("sessions").insert({
            request_id: requestId,
            scheduled_at: date.toISOString()
        });

        if (error) return toast(error.message);
        toast("Session scheduled!");
    }

    // EVENT LISTENERS

    $("loginNav").addEventListener("click", () => showModal("login"));
    $("signupNav").addEventListener("click", () => showModal("signup"));
    $("heroSignup").addEventListener("click", () => showModal("signup"));
    $("closeModal").addEventListener("click", closeModal);
    $("authForm").addEventListener("submit", handleAuth);
    $("saveProfile").addEventListener("click", saveProfile);
    $("addSkill").addEventListener("click", addSkill);
    $("searchBtn").addEventListener("click", loadSkills);

    $("logoutBtn").addEventListener("click", async () => {
        const { error } = await client.auth.signOut();
        if (error) return toast(error.message);
        toast("Logged out.");
    });

    $("skillSearch").addEventListener("keydown", event => {
        if (event.key === "Enter") loadSkills();
    });

    $("categoryFilter").addEventListener("change", loadSkills);

    $("authSwitch").addEventListener("click", event => {
        if (event.target.id === "switchAuth") {
            showModal(authMode === "signup" ? "login" : "signup");
        }
    });

    document.addEventListener("click", event => {
        const target = event.target;

        if (target.matches(".request-skill, .request-match")) {
            sendRequest(target.dataset.user);
        }

        if (target.matches(".accept-request")) {
            updateRequest(target.dataset.id, "accepted");
        }

        if (target.matches(".reject-request")) {
            updateRequest(target.dataset.id, "rejected");
        }

        if (target.matches(".open-chat")) {
            openChat(target.dataset.id);
        }

        if (target.matches(".schedule-session")) {
            scheduleSession(target.dataset.id);
        }
    });

    client.auth.onAuthStateChange((_event, session) => {
        currentUser = session?.user || null;
        setTimeout(updateUI, 0);
    });

    async function init() {
        const { data } = await client.auth.getSession();
        currentUser = data.session?.user || null;
        await updateUI();
        await loadSkills();
    }

    init();
})();
