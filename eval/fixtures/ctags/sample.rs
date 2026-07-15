pub struct Session {
    token: String,
}

impl Session {
    pub fn new(token: String) -> Self {
        Session { token }
    }
    fn validate(&self) -> bool {
        !self.token.is_empty()
    }
}

pub fn create_session(token: String) -> Session {
    Session::new(token)
}
