namespace CivVIAccess.Launcher;

public  sealed class Mediator
{
    private readonly AccessibleOutputHandler accessibleOOutput;
    private readonly TextOutputHandler textOutput;

    public Mediator(AccessibleOutputHandler accessibleOutput, TextOutputHandler textOutput)
    {
        this.accessibleOOutput = accessibleOutput;
        this.textOutput = textOutput;
    }

    public void Output(string message)
    {
        this.accessibleOOutput.OutputMessage(message);
    }

    public void OutputText(string message)
    {
        this.textOutput.OutputLine(message);
    }

    public void OutputTextError(string message)
    {
        this.textOutput.OutputErrorLine(message);
    }
}
