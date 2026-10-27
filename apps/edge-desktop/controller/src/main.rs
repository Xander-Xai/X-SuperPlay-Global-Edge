use std::env;
use std::io::{self, BufRead};

use x_superplay_edge_controller::{
    AuthCredential, Authenticator, Controller, ErrorBody, Request, Response, ResponseBody,
};

fn main() {
    let credential = env::var("CONTROLLER_CREDENTIAL").unwrap_or_default();
    if credential.is_empty() {
        print_response(&Response::new(ResponseBody::Error(
            ErrorBody::unauthorized(),
        )));
        return;
    }

    let profiles = env::var("CONTROLLER_PROFILES")
        .unwrap_or_else(|_| "reality,hysteria2,wireguard".to_string());
    let mut controller = Controller::new(
        Authenticator::new(AuthCredential::from_hex(credential.clone())),
        profiles
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
    );

    let mut line = String::new();
    let response = match io::stdin().lock().read_line(&mut line) {
        Ok(_) => match serde_json::from_str::<Request>(&line) {
            Ok(request) => controller.handle(request, Some(&credential)),
            Err(_) => Response::new(ResponseBody::Error(ErrorBody::invalid_request(
                "invalid request JSON",
            ))),
        },
        Err(_) => Response::new(ResponseBody::Error(ErrorBody::invalid_request(
            "could not read request",
        ))),
    };
    print_response(&response);
}

fn print_response(response: &Response) {
    match serde_json::to_string(response) {
        Ok(serialized) => println!("{serialized}"),
        Err(_) => println!(
            "{{\"contract_version\":\"1\",\"code\":\"internal\",\"category\":\"internal\",\"retryable\":false,\"message\":\"serialization failed\"}}"
        ),
    }
}
