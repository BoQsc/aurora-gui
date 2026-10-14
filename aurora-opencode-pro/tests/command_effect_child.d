module command_effect_child;
import std.file : readText, write;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : seconds;
int main(string[] args)
{
    if(args[1] == "read") writeln(readText(args[2]));
    else if(args[1] == "write") write(args[2], "int value = 2;\n");
    else if(args[1] == "sleep") Thread.sleep(2.seconds);
    else if(args[1] == "fail") return 1;
    return 0;
}
