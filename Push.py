import subprocess
import argparse
import sys


def run_command(command, check=True, capture=False):
    """Run a shell command."""
    print(f"\n>>> {command}")
    result = subprocess.run(
        command,
        shell=True,
        text=True,
        capture_output=capture
    )

    if capture:
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)

    if check and result.returncode != 0:
        print(f"\nCommand failed with exit code {result.returncode}")
        sys.exit(result.returncode)

    return result


def confirm(prompt):
    """Ask user for confirmation."""
    while True:
        answer = input(f"{prompt} [y/n]: ").strip().lower()
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("Please enter y or n.")


def working_tree_changed():
    """
    Return True if there are any tracked/untracked changes.
    Uses porcelain output for reliable parsing.
    """
    result = subprocess.run(
        "git status --porcelain",
        shell=True,
        text=True,
        capture_output=True
    )

    if result.returncode != 0:
        print("Failed to check git status.")
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(result.returncode)

    return bool(result.stdout.strip())


def staged_changes_exist():
    """Return True if there are staged changes ready to commit."""
    result = subprocess.run(
        "git diff --cached --quiet",
        shell=True
    )
    return result.returncode == 1


def manual_confirm_mode():
    print("CONFIRM MODE")

    run_command("git status", capture=True)

    if not working_tree_changed():
        print("\nNothing changed. No add, commit, or push needed.")
        return

    if not confirm("Run git add . ?"):
        print("Stopped before add.")
        return
    run_command("git add .")

    run_command("git status", capture=True)

    if not staged_changes_exist():
        print("\nNothing staged after git add .. Nothing to commit.")
        return

    if not confirm("Run git commit ?"):
        print("Stopped before commit.")
        return

    message = input("Enter commit message: ").strip()
    if not message:
        print("Commit message cannot be empty.")
        return

    run_command(f'git commit -m "{message}"')

    if not confirm("Run git push ?"):
        print("Stopped before push.")
        return

    run_command("git push")
    print("\nDone.")


def auto_mode(message):
    print("AUTO MODE")

    run_command("git status", capture=True)

    if not working_tree_changed():
        print("\nNothing changed. No add, commit, or push needed.")
        return

    run_command("git add .")

    if not staged_changes_exist():
        print("\nNothing staged after git add .. Nothing to commit.")
        return

    run_command(f'git commit -m "{message}"')
    run_command("git push")
    print("\nDone.")


def main():
    parser = argparse.ArgumentParser(
        description="Simple git helper: status, add ., commit, push"
    )
    parser.add_argument(
        "--auto",
        action="store_true",
        help="Run automatically without step confirmations"
    )
    parser.add_argument(
        "-m",
        "--message",
        help="Commit message (required in auto mode)"
    )

    args = parser.parse_args()

    if args.auto:
        if not args.message or not args.message.strip():
            print("Auto mode requires a commit message: -m \"your message\"")
            return
        auto_mode(args.message.strip())
    else:
        manual_confirm_mode()


if __name__ == "__main__":
    main()