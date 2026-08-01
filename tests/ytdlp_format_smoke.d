module tests.ytdlp_format_smoke;

import auroracut.ytdlp : normalizeYtDlpMaxHeight, ytDlpMaxWidthForHeight,
    ytDlpVideoFormatForHeight, ytDlpVideoSortForHeight;

int main()
{
    assert(normalizeYtDlpMaxHeight(1080) == 1080);
    assert(normalizeYtDlpMaxHeight(720) == 720);
    assert(normalizeYtDlpMaxHeight(9999) == 1080);
    assert(ytDlpMaxWidthForHeight(1080) == 1920);
    assert(ytDlpMaxWidthForHeight(720) == 1280);
    assert(ytDlpVideoFormatForHeight(1080) ==
        "bv*[height=1080][width=1920]+ba/b[height=1080][width=1920]/" ~
        "bv*[height<=1080][width<=1920]+ba/b[height<=1080][width<=1920]");
    assert(ytDlpVideoFormatForHeight(480) ==
        "bv*[height=480][width=854]+ba/b[height=480][width=854]/" ~
        "bv*[height<=480][width<=854]+ba/b[height<=480][width<=854]");
    assert(ytDlpVideoSortForHeight(1080) ==
        "res:1080,width:1920,fps,vcodec:h264,acodec:m4a,ext:mp4:m4a");
    return 0;
}
