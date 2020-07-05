//
//  OpenCVWrapper.m
//  TrueDepthStreamer
//
//  Created by kayo on 2019/4/19.
//  Copyright © 2019 Apple. All rights reserved.
//

#import <opencv2/opencv.hpp>
#import "OpenCVWrapper.hpp"
#import <fstream>

#define DEPTH_THRESH 3
#define VECTOR_THRESH 10
#define JUMP_THRESH 15
#define GBLUR_SIGMA 5
#define LOWER_GRAY 50
#define MIN_HANDSIZE 5000

// constants for finger identification
#define WINDOW 6
#define MIN_FIN_LEN 40 //minimum pixels to be a valid finger, to rule out thumbs
#define MIN_FIN_INTEVAL 25

#define DIS_SIZE 6

#define cameraOx 2029.3673
#define cameraOy 1514.6548
#define cameraFx 2746.3894
#define cameraFy 2746.3894
#define referenceWidth 4032
#define referenceHeight 3024

#define THUMB_MAX 15

@implementation OpenCVWrapper

struct Centroid {
    double ux, uy, sx, sy;
    void update(double a, double b) {
        ux = a;
        uy = b;
    }
    friend std::ostream &operator<<( std::ostream &output, const Centroid& c ) {
        output << c.ux << " " << c.uy << " " << c.sx << " " << c.sy;
        return output;
    }
};

struct Pos {
    double x, y;
};

const int MAX_WORD_LEN = 20;
const double PI = 3.1415926;
static constexpr double DOUBLE_MIN = std::numeric_limits<double>::lowest();
int word_len = 0; //current candidate word length
std::vector<std::string> candWords;
std::vector<std::unordered_map<std::string, double>> words;
std::unordered_map<char, Centroid> centroids; //the centroids of every character
std::vector<std::unordered_map<char, double>> lookup_table;

struct Finger {
    int pos;
    int pixels;
};

const int LEN = 7;
struct RingQueue {
    int index = 0;
    int arr[LEN] = {0};
    void insert(int val) {
        arr[index] = val;
        index = (index + 1) % LEN;
    }
    int getFirst() {
        return arr[index];
    }
    int getLast() {
        return arr[(index+LEN-1)%LEN];
    }
    void clear() {
        for(int i = 0; i < LEN; i++) arr[i] = 0;
    }
};
RingQueue rightQueue, leftQueue;
RingQueue vQueueL, vQueueR;


+ (NSString *)openCVVersionString {
    return [NSString stringWithFormat:@"OpenCV Version %s",  CV_VERSION];
}

- (void)isThisWorking {
    std::cout << "hello world" << std::endl;
}

- (cv::Mat)cvMatGrayFromUIImage:(UIImage *)image {
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image.CGImage);
    CGFloat cols = image.size.width;
    CGFloat rows = image.size.height;
    
    cv::Mat cvMat(rows, cols, CV_8UC1); // 8 bits per component, 1 channels
    
    CGContextRef contextRef = CGBitmapContextCreate(cvMat.data,                 // Pointer to data
                                                    cols,                       // Width of bitmap
                                                    rows,                       // Height of bitmap
                                                    8,                          // Bits per component
                                                    cvMat.step[0],              // Bytes per row
                                                    colorSpace,                 // Colorspace
                                                    kCGImageAlphaNoneSkipLast |
                                                    kCGBitmapByteOrderDefault); // Bitmap info flags
    
    CGContextDrawImage(contextRef, CGRectMake(0, 0, cols, rows), image.CGImage);
    CGContextRelease(contextRef);
    
    return cvMat;
}

-(UIImage *)UIImageFromCVMat:(cv::Mat)cvMat
{
    NSData *data = [NSData dataWithBytes:cvMat.data length:cvMat.elemSize()*cvMat.total()];
    CGColorSpaceRef colorSpace;
    
    if (cvMat.elemSize() == 1) {
        colorSpace = CGColorSpaceCreateDeviceGray();
    } else {
        colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    
    // Creating CGImage from cv::Mat
    CGImageRef imageRef = CGImageCreate(cvMat.cols,                                 //width
                                        cvMat.rows,                                 //height
                                        8,                                          //bits per component
                                        8 * cvMat.elemSize(),                       //bits per pixel
                                        cvMat.step[0],                              //bytesPerRow
                                        colorSpace,                                 //colorspace
                                        kCGImageAlphaNone|kCGBitmapByteOrderDefault,// bitmap info
                                        provider,                                   //CGDataProviderRef
                                        NULL,                                       //decode
                                        false,                                      //should interpolate
                                        kCGRenderingIntentDefault                   //intent
                                        );
    
    
    // Getting UIImage from CGImage
    UIImage *finalImage = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
    return finalImage;
}

void floodfill(cv::Mat &mat, int j, int i) {
    //    printf("%d %d\n", j, i);
    mat.at<uchar>(j, i) = 0;
    if (i > 0 && mat.at<uchar>(j, i - 1) != 0)
        floodfill(mat, j, i - 1);
    if (j > 0 && mat.at<uchar>(j - 1, i) != 0)
        floodfill(mat, j - 1, i);
    if (mat.at<uchar>(j, i + 1) != 0)
        floodfill(mat, j, i + 1);
}

float calc_depth(std::vector<int>&vec) {
    int sum = 0, length = int(vec.size());
    std::sort(vec.begin(),  vec.end());
    for (int i = 0; i < DEPTH_THRESH; i++) {
        sum += vec[i];
    }
    return sum / (float)DEPTH_THRESH;
}

bool nearcheck(cv::Mat &mat, int j, int i, int lo, int hi) {
    int window = 8;
    for (int jj = j - window; jj < j + window; jj++)
        for (int ii = i - window; ii < i + window; ii++)
            if (mat.at<uchar>(jj, ii) < lo || mat.at<uchar>(jj, ii) > hi) {
                return false;
            }
    return true;
}

bool x_axis_compare ( cv::Point3f a, cv::Point3f b) {
    if (a.x < b.x) return true;
    else return false;
}

float calc_distance (cv::Point3f a, cv::Point3f b) {
    return (a.x-b.x)*(a.x-b.x) + (a.z-b.z)*(a.z-b.z);
}

int lastX = 0;
int lastY = 0;
+ (NSDictionary*) showContours:(CVPixelBufferRef)pixelBuffer
                   bg:(CVImageBufferRef)background
                   to:(CVPixelBufferRef)toBuffer
                press:(BOOL)pressed
            curLength:(int)curLen
{
    BOOL flag = false;
    int touchX = 0, touchY = 0;
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseaddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    
    CGFloat width = CVPixelBufferGetWidth(pixelBuffer);
    CGFloat height = CVPixelBufferGetHeight(pixelBuffer);
    
    cv::Mat canvas;
    canvas.create(height, width, CV_8UC4);
    
    
    cv::Mat mat(height, width, CV_16FC1, baseaddress, 0);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CVPixelBufferLockBaseAddress(background, 0);
    void *baseaddress_bg = CVPixelBufferGetBaseAddressOfPlane(background, 0);
    
    CGFloat width_bg = CVPixelBufferGetWidth(background);
    CGFloat height_bg = CVPixelBufferGetHeight(background);
    
    cv::Mat bg_mat(height, width, CV_8UC4, baseaddress_bg, 0);
    CVPixelBufferUnlockBaseAddress(background, 0);
    
    
    mat *= 100;

    mat.convertTo(mat, CV_32F);
    cv::Mat depthMat = mat.clone(); //depth information for every pixel
    
    mat.convertTo(mat, CV_8UC1);
    
    cv::Mat mask;
    mask.create(height, width, CV_8UC4);
    cv::inRange(mat, 15, 40, mask);
    cv::bitwise_and(mat, mask, mat);
    mat = (mat - 15) * (255 / (40-15.0)); //convert to 255 scale

    std::vector<std::vector<cv::Point> > contours;
    std::vector<cv::Vec4i> hierarchy;

    //cv::GaussianBlur(mat, mat, cv::Size(GBLUR_SIGMA, GBLUR_SIGMA), 0);
//    cv::threshold(mat, mat, LOWER_GRAY, 255, cv::THRESH_BINARY);
    cv::findContours(mat, contours, hierarchy, cv::RETR_TREE, cv::CHAIN_APPROX_SIMPLE);

    //    cv::cvtColor(mat, mat, cv::COLOR_GRAY2BGRA);

    int size = contours.size();
    // printf("%d\n", size);
    //    cv::Scalar colorContour = cv::Scalar( 255, 0, 0 );
    //    cv::Scalar colorHull = cv::Scalar( 0, 255, 0 );

    std::vector<cv::Point> fingers;
    std::vector<cv::Point3f> fingers3D;

    cv::Mat grayMat = mat.clone();
    cv::cvtColor(mat, mat, cv::COLOR_GRAY2BGRA);
    
    float realX = 0.0, realY = 0.0;
    float distance = 100;
    int xcoord = -1, ycoord = -1;
    bool moveLeft = false, moveRight = false;
    bool moveUp = false;
    bool validTouch = false;
    bool thumbTouch = false; //touch with thumb
    int touchHand = 0; //0 is lefthand, 1 is righthand

    if (size >= 2) { //at least two coutours appear

        int largestContour = 0;
        int secondLargestContour = 1;

        std::vector<double> contourArea;

        for (int i = 0; i < size; i++)
            contourArea.push_back(cv::contourArea(contours[i]));
        
        //find the first and second largest contour
        for (int i = 1; i < size; i++)
        {
            if (contourArea[i] > contourArea[largestContour]) {
                secondLargestContour = largestContour;
                largestContour = i;
            } else if (contourArea[i] > contourArea[secondLargestContour]) {
                secondLargestContour = i;
            }
        }

        int inds[] = {largestContour, secondLargestContour};

        if(inds[0] != inds[1] && contourArea[inds[0]] >= MIN_HANDSIZE && contourArea[inds[1]] >= MIN_HANDSIZE) {
            cv::Point br0 = cv::boundingRect(contours[inds[0]]).br();
            cv::Point br1 = cv::boundingRect(contours[inds[1]]).br();

            int leftIdx = (br0.x > br1.x) ? 0 : 1;
            cv::Rect leftRect = cv::boundingRect(contours[inds[leftIdx]]);
            cv::Rect rightRect = cv::boundingRect(contours[inds[1^leftIdx]]);
//            
            cv::rectangle(mat, leftRect.tl(), leftRect.br(), cv::Scalar(0, 0, 255));
            cv::rectangle(mat, rightRect.tl(), rightRect.br(), cv::Scalar(0, 255, 0));
//            std::cout << leftRect.tl().x << std::endl;
//            std::cout << rightRect.br().x << std::endl;
            rightQueue.insert(rightRect.br().x);
            leftQueue.insert(leftRect.tl().x);
            vQueueL.insert(leftRect.tl().y);
            vQueueR.insert(rightRect.tl().y);
            if(vQueueL.getFirst() != 0 && vQueueL.getLast() != 0 && vQueueL.getFirst() - vQueueL.getLast() > 100) {
//                std::cout << "move up" << std::endl;
                moveUp = true;
                vQueueL.clear();
                vQueueR.clear();
            } else if(vQueueR.getFirst() != 0 && vQueueR.getLast() != 0 && vQueueR.getFirst() - vQueueR.getLast() > 100) {
//                std::cout << "move up" << std::endl;
                moveUp = true;
                vQueueR.clear();
                vQueueL.clear();
            }
            
            if(rightQueue.getFirst() != 0 && rightQueue.getLast() != 0 && rightQueue.getFirst() - rightQueue.getLast() > 100) {
//                std::cout << "move right" << std::endl;
                moveRight = true;
                rightQueue.clear();
            }
            if(leftQueue.getFirst() != 0 && leftQueue.getLast() != 0 && leftQueue.getFirst() - leftQueue.getLast() < -100) {
//                std::cout << "move left" << std::endl;
                moveLeft = true;
                leftQueue.clear();
            }

            int bottom0 = br0.y, bottom1 = br1.y;

            int target;
            if(bottom0 < bottom1) {
                target = inds[1];
            } else if(bottom1 < bottom0) {
                target = inds[0];
            } else { //two hands in the same height
//                std::cout << "unexpected" << std::endl;
                target = inds[0];
            }

            cv::Rect handRect = cv::boundingRect(contours[target]);
            cv::Point tl = handRect.tl();
            cv::Point br = handRect.br();

            if(pressed == true) {
//                std::cout << "bottom " << br.y << std::endl;
                
                float last_total_depth = 0, last_cnt = 0;
                std::vector<float> last_all_dis;
                for(int i = MAX(0, lastX-1); i <= MIN(width, lastX+1); i++) {
                    for(int j = MAX(0, lastY-5); j < MIN(height, lastY-2); j++) {
                        float val = depthMat.at<float>(cv::Point(i, j));
                        if(val > 15 && val < 40) {
                            last_all_dis.push_back(val);
                        }
                    }
                }
                last_cnt = MIN(last_all_dis.size(), DIS_SIZE);
                 std::sort(last_all_dis.begin(), last_all_dis.end());
                for(int i = 0; i < last_cnt; i++) {
                    last_total_depth += last_all_dis[i];
                }
                
                for(cv::Point p : contours[target]) {
                    if(abs(p.y - br.y) <= 2) {
                        validTouch = true;
                        std::vector<float> all_dis;
                        float total_depth = 0;
                        int cnt = 0;
                        for(int i = MAX(tl.x, p.x - 3); i <= MIN(br.x, p.x + 3); i++) {
                            for(int j = tl.y + 1; j <= p.y - 2; j++) {
                                float val = depthMat.at<float>(cv::Point(i, j));
                                if(val > 15 && val < 39) {
//                                    std::cout << i << " " << j << " " << val << "  ";
                                    all_dis.push_back(val);
//                                    total_depth += val;
//                                    cnt++;
                                }
                            }
                        }
//                        std::cout << std::endl;
                        std::sort(all_dis.begin(), all_dis.end());
                        cnt = MIN(all_dis.size(), DIS_SIZE);
                        for(int i = 0; i < cnt; i++) {
                            total_depth += all_dis[i];
                        }
                        
                        if(total_depth / cnt < distance) {
                            distance = total_depth / cnt;
                            xcoord = p.x;
                            ycoord = p.y;
                        }
                        
                        
                    }
                    lastX = xcoord;
                    lastY = ycoord;
                }
                cv::line(mat, cv::Point(xcoord, 0), cv::Point(xcoord, ycoord), cv::Scalar(0, 255, 0), 2);
                float xRatio = (float)xcoord / 640;
                float yRatio = (float)ycoord / 480;
                realX = (xRatio * referenceWidth - cameraOx) * distance / cameraFx;
                realY = (yRatio * referenceHeight - cameraOy) * distance / cameraFy;
                if(abs(distance - 100.0) < 1) validTouch = false;
                else {
                    validTouch = true;
//                    if( (candWords.size() != 0 && candWords[0].length() == curLen) || curLen == -1 ) {
//                        thumbTouch = true;
//                    }
                    if(distance > 35) thumbTouch = true;
                    if(target == inds[leftIdx]) { //touch with left hand
//                        if(xcoord - tl.x <= THUMB_MAX) thumbTouch = true;
                        touchHand = 0;
                    } else { //touch with right hand
//                        if(br.x - xcoord <= THUMB_MAX) thumbTouch = true;
                        touchHand = 1;
                    }
//                    std::cout << thumbTouch << std::endl;
                }
                //std::cout << "dis " << distance << " " << xcoord << " " << ycoord << " " << realX << " " << realY << std::endl;
            }
            
            std::vector<int> sum_array;
            std::vector<int> num_array;
            std::vector<Finger> cand_array;

            for(int i = tl.x; i < br.x; i++) {
                int sum = 0, num = 0;
                for(int j = tl.y; j < br.y; j++) {
                    int val = grayMat.at<uchar>(j, i);
                    if(100 < val && val < 230) {
                        sum += val;
                        num++;
                    }
                }
                sum_array.push_back(sum);
                num_array.push_back(num);
            }

            std::vector<Finger> fingers;
            for(int i = 0; i < sum_array.size(); i++) {
                int val = sum_array[i];
                bool isLocalMax = true;
                for(int j = MAX(i - WINDOW, 0); j < MIN(i + WINDOW, sum_array.size()); j++) {
                    if(val < sum_array[j]) {
                        isLocalMax = false;
                        break;
                    }
                }
                if(isLocalMax && num_array[i] > MIN_FIN_LEN) {
                    fingers.push_back({i+tl.x, num_array[i]});
                }
            }

            //Remove close lines
            for (int i = 0; i < fingers.size(); i++) {
                for (int j = i + 1; j < fingers.size(); j++) {
                    if (abs(fingers[i].pos - fingers[j].pos) < MIN_FIN_INTEVAL) {
                        fingers.erase(fingers.begin() + j);
                        j--;
                    }
                }
            }

//            for(Finger item : fingers) {
//                int i = item.pos;
//                cv::line(mat, cv::Point(i, 0), cv::Point(i, tl.y - 5), cv::Scalar(0, 255, 0), 2);
//            }

//            if(fingers.size() != 4) flag = true;
            flag = true;

        }
    }

    if(moveLeft) {
        [self newWord];
    } else if(moveRight) {
        
    } else if(thumbTouch) { //confirm
        [self newWord];
    } else if(validTouch && !thumbTouch) {
        newTap(realX, distance);
        candWords = getCandidateWords();
    }

    
    CVPixelBufferLockBaseAddress(toBuffer, 0);
    void *mybase = CVPixelBufferGetBaseAddress(toBuffer) ;
    memcpy(mybase, mat.data, mat.total()*4);
    CVPixelBufferUnlockBaseAddress(toBuffer, 0);

    NSMutableArray *wordArray = [[NSMutableArray alloc] init];
    if(candWords.size() != 0) {
        for(int i = 0; i < 5; i++) {
            NSString *str = [NSString stringWithCString:candWords[i].c_str() encoding:[NSString defaultCStringEncoding]];
            [wordArray addObject:str];
        }
    } else {
        for(int i = 0; i < 5; i++) {
            NSString *str = @"";
            [wordArray addObject:str];
        }
    }
   
    NSDictionary *dict = @{@"validTouch":[NSNumber numberWithBool:validTouch], @"touchX":[NSNumber numberWithFloat:realX], @"touchY": [NSNumber numberWithFloat:realY], @"touchZ":[NSNumber numberWithFloat:distance], @"moveLeft":[NSNumber numberWithBool:moveLeft], @"moveRight":[NSNumber numberWithBool:moveRight], @"moveUp":[NSNumber numberWithBool:moveUp], @"xcoord":[NSNumber numberWithInt:xcoord], @"ycoord":[NSNumber numberWithInt:ycoord], @"thumb":[NSNumber numberWithBool: thumbTouch], @"touchHand":[NSNumber numberWithInt: touchHand], @"words": wordArray};
    return dict;
}

+(void) newWord { //clear everything
    word_len = 0;
    candWords.clear();
    for(int i = 0; i < MAX_WORD_LEN; i++) {
        lookup_table[i].clear();
    }
}

+(void) loadData { //load data
    NSString* fileRoot = [[NSBundle mainBundle] pathForResource:@"wordslib" ofType:@"csv"];
    std::ifstream wordsFile([fileRoot UTF8String]);
    std::string s;
    std::vector<std::string> rowInfo;
    
    for(int i = 0; i < MAX_WORD_LEN; i++) {
        std::unordered_map<std::string, double> map;
        words.push_back(map);
        
        std::unordered_map<char, double> map1;
        lookup_table.push_back(map1);
    }
    
    while(getline(wordsFile, s)) {
        mySplit(s, ",", rowInfo);
        std::stringstream ss;
        ss << rowInfo[1];
        double freq;
        ss >> freq;
        int len = rowInfo[0].length();
        words[len-1][rowInfo[0]] = log( freq );
    }
    
    fileRoot = [[NSBundle mainBundle] pathForResource:@"centroids" ofType:@"csv"];
    std::ifstream centerFile([fileRoot UTF8String]);
    std::vector<std::string> infor; std::string row;
    while(getline(centerFile, row)) {
        mySplit(row, ",", infor);
        std::stringstream ss;
        ss << infor[0];
        char c;
        ss >> c;
        double ux, uy, sx, sy;
        std::stringstream ss1; ss1 << infor[1]; ss1 >> ux;
        std::stringstream ss2; ss2 << infor[2]; ss2 >> uy;
        std::stringstream ss3; ss3 << infor[3]; ss3 >> sx;
        std::stringstream ss4; ss4 << infor[4]; ss4 >> sy;
        centroids[c] = Centroid{ux, uy, sx, sy};
    }
}

double calPsi(char c, double x, double y) {
    double z = pow(x-centroids[c].ux,2)/pow(centroids[c].sx,2) + pow(y-centroids[c].uy, 2)/pow(centroids[c].sy, 2);
    return log( 1/(2*PI*centroids[c].sx*centroids[c].sy)*exp(-0.5*z) );
}

void newTap(double x, double y) { //calculate probability of this tap for each char
    for(int c = 97; c < 123; c++) {
        lookup_table[word_len][char(c)] = calPsi(c, x, y);
//        all += lookup_table[word_len][char(c)];
    }
//    lookup_table[word_len]['0'] = calPsi('0', x, y); //第i次点击为字母char的概率
    word_len = word_len + 1;
}

std::vector<std::string> getCandidateWords() {
    double max_prob1 = DOUBLE_MIN;
    double max_prob2 = DOUBLE_MIN;
    double max_prob3 = DOUBLE_MIN;
    double max_prob4 = DOUBLE_MIN;
    double max_prob5 = DOUBLE_MIN;
    std::string max_word1, max_word2, max_word3, max_word4, max_word5;
    std::vector<std::string> ans;

    for(std::unordered_map<std::string, double>::iterator i = words[word_len-1].begin(); i != words[word_len-1].end(); i++) {
        std::string word = i->first;
        double prob = i->second;
        for(int i = 0; i < word.length(); i++) {
            char c = word[i];
            prob += lookup_table[i][c];
        }
        // cout << prob << endl;
        if(prob > max_prob1) {
            max_prob5 = max_prob4;
            max_word5 = max_word4;
            max_prob4 = max_prob3;
            max_word4 = max_word3;
            max_prob3 = max_prob2;
            max_word3 = max_word2;
            max_prob2 = max_prob1;
            max_word2 = max_word1;
            max_prob1 = prob;
            max_word1 = word;
        } else if(prob > max_prob2) {
            max_prob5 = max_prob4;
            max_word5 = max_word4;
            max_prob4 = max_prob3;
            max_word4 = max_word3;
            max_prob3 = max_prob2;
            max_word3 = max_word2;
            max_prob2 = prob;
            max_word2 = word;
        } else if(prob > max_prob3) {
            max_prob5 = max_prob4;
            max_word5 = max_word4;
            max_prob4 = max_prob3;
            max_word4 = max_word3;
            max_prob3 = prob;
            max_word3 = word;
        } else if(prob > max_prob4) {
            max_prob5 = max_prob4;
            max_word5 = max_word4;
            max_prob4 = prob;
            max_word4 = word;
        } else if(prob > max_prob5) {
            max_prob5 = prob;
            max_word5 = word;
        }
    }
    ans.push_back(max_word1); ans.push_back(max_word2); ans.push_back(max_word3); ans.push_back(max_word4); ans.push_back(max_word5);
    return ans;
}

void mySplit(std::string str, std::string separator, std::vector<std::string> &result) {//对每一行以逗号为分隔符进行分割
    result.clear();
    int cutAt;
    while( (cutAt = str.find_first_of(separator)) != str.npos )
    {
        if(cutAt > 0)
        {
            result.push_back(str.substr(0, cutAt));
        }
        str = str.substr(cutAt + 1);
    }
    if(str.length() > 0)
    {
        result.push_back(str);
    }
}

@end
