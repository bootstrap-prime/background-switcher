// put socket at /tmp/random-background.socket
// accept data from there
// parse config file at $XDG_CONFIG_DIR/background/config.toml

use std::{
    env, fs,
    io::stdin,
    path::PathBuf,
    process::{Child, Command},
    thread,
    time::Duration,
};

use anyhow::bail;
use directories::ProjectDirs;
use rand::{seq::SliceRandom, thread_rng};

#[derive(serde::Deserialize)]
struct Config {
    categories: Vec<(String, Vec<PathBuf>)>,
    feh_arg: String,
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    let mut choice = String::new();

    if args.len() == 2 {
        choice = dbg!(args[1].clone());
    } else if args.len() == 1 {
        choice = "query".to_string();
    }

    let config = get_categories()?;

    let mut command_handle: Option<Child> = None;

    match choice.trim() {
        "query" => {
            config
                .categories
                .iter()
                .inspect(|(e, _)| println!("{}", e))
                .fold(0, |e, _| e);

            println!("random");
        }
        "random" => {
            command_handle = Some(select_random()?);
        }
        _ => {
            if let Some((_, loc)) = &config
                .categories
                .iter()
                .find(|(name, _)| name == choice.trim())
            {
                let mut command = Command::new("feh");
                command.arg(config.feh_arg.as_str());

                for path in loc {
                    command.arg("--randomize").arg(path.to_str().unwrap());
                }

                command_handle = Some(command.spawn()?);
            } else {
                eprintln!("unsupported choice selected. ignoring.");
            }
        }
    }

    if let Some(mut handle) = command_handle {
        // rust is too blazing fast. sleep before quitting to let feh have time to run.
        thread::sleep(Duration::from_millis(200));

        handle.kill()?;
    }
    Ok(())
}

// rofi supports custom error messages, but I should just be good and not make mistakes.
// I don't want to implement that right now.

fn select_random() -> anyhow::Result<Child> {
    let config = get_categories()?;

    let mut rng = thread_rng();
    let (_, paths) = config.categories.choose(&mut rng).unwrap();

    let mut binding = Command::new("feh");
    binding.arg(config.feh_arg.as_str());

    for path in paths {
        binding.arg("--randomize").arg(path.to_str().unwrap());
    }

    Ok(binding.spawn()?)
}

fn get_categories() -> anyhow::Result<Config> {
    let platform_dirs = ProjectDirs::from("com", "bootstrap", "random-background")
        .expect("failed to find config directory on platform.");

    let config_path = platform_dirs.config_dir().join("config.toml");

    if !config_path.exists() {
        anyhow::bail!(
            "Config file {} does not exist. An example config file can be found in the repo.",
            config_path.to_string_lossy()
        );
    }

    let mut config: Config = toml::from_str(fs::read_to_string(config_path)?.as_str())?;

    let categories = config.categories.clone();

    let categories: Vec<(String, Vec<PathBuf>)> = categories
        .into_iter()
        .map(|(name, paths)| {
            let paths: Vec<PathBuf> = paths
                .iter()
                .map(|e| {
                    fs::canonicalize(nu_path::expand_tilde(e))
                        .expect(&format!("file does not exist: {}", e.to_string_lossy()))
                })
                .collect();

            (name, paths)
        })
        .collect();

    config.categories = categories;

    Ok(config)
}
